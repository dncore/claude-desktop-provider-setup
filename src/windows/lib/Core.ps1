# Normative resolution core, Windows implementation.
# Mirrors src/common/SPEC.md sections 1-6 and the plan contract in 12.
# Every divergence from src/macos/lib/core.sh is a defect that
# tests/run-conformance.ps1 and tests/run-conformance.sh must catch.

$script:Core = @{
    BaseUrl         = ''
    BaseHost        = ''
    AuthScheme      = ''
    TokenSource     = ''
    Token           = ''
    DefaultModel    = ''
    HelperTtl       = 900
    DeploymentMode  = '3p'
    AllowHttp       = $false
    Discovery       = ''        # '', 'true', 'false'
    AllowUnlisted   = $false
    MappingPath     = ''
    Models          = New-Object System.Collections.ArrayList
    MapIds          = New-Object System.Collections.ArrayList
    MapFields       = New-Object System.Collections.ArrayList
}

function Get-Core { return $script:Core }

function Read-SettingsDocument {
    if (-not (Test-Path -LiteralPath $script:State.Settings)) { return $null }
    if (-not (Test-Path -LiteralPath $script:State.Settings -PathType Leaf)) { return $null }
    try {
        return (Read-JsonFile $script:State.Settings)
    } catch {
        Stop-WithError 3 'invalid-json' "$($script:State.Settings) is not valid JSON"
    }
}

function Get-SettingsValue {
    param($Settings, [string]$Path)
    $node = $Settings
    foreach ($seg in $Path.Split('.')) {
        $node = Get-Prop $node $seg
        if ($null -eq $node) { return '' }
    }
    if ($node -is [string]) { return $node }
    return [string]$node
}

function Resolve-Pick {
    param($Settings, [string]$KeyPath, [string]$EnvName)
    $fromSettings = ConvertTo-Trimmed (Get-SettingsValue $Settings $KeyPath)
    $fromEnv      = ConvertTo-Trimmed (Get-EnvOrEmpty $EnvName)

    if ($fromSettings -ne '' -and $fromEnv -ne '' -and $fromSettings -cne $fromEnv) {
        Add-Warning 'env-shadowed' $EnvName
    }
    if ($fromSettings -ne '') { return $fromSettings }
    return $fromEnv
}

function Test-BaseUrl {
    param([string]$Raw)
    $url = ConvertTo-Trimmed $Raw

    if ($url -eq '') { Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL is empty' }
    Assert-Clean $url 'ANTHROPIC_BASE_URL'

    $forbidden = @([char]' ', [char]'"', [char]'<', [char]'>', [char]'\', [char]'^', [char]'`', [char]'{', [char]'|', [char]'}')
    foreach ($c in $forbidden) {
        if ($url.IndexOf($c) -ge 0) {
            Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL contains a character that cannot appear in a URL'
        }
    }

    if ($url -notmatch '^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)(.*)$') {
        Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL has no scheme; expected https://host/...'
    }
    $scheme    = $Matches[1]
    $authority = $Matches[2]

    if ($authority.Contains('@')) {
        Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL must not embed credentials (user@host)'
    }

    if ($scheme -cne 'https') {
        if ($scheme -cne 'http') {
            Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL scheme must be https'
        }
        if (-not $script:Core.AllowHttp) {
            Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL uses http, so the credential would cross the network in cleartext. Use https, or pass --allow-http for loopback testing only.'
        }
        Add-Warning 'insecure-http' $authority
    }

    if ($url.EndsWith('/')) {
        $url = $url.TrimEnd('/')
        Add-Warning 'trailing-slash' 'removed trailing slash'
    }

    $len = Get-ByteLength $url
    if ($len -lt 8)    { Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL is too short' }
    if ($len -gt 2048) { Stop-WithError 3 'invalid-base-url' 'ANTHROPIC_BASE_URL is too long' }

    $script:Core.BaseUrl  = $url
    $script:Core.BaseHost = ($authority -split ':')[0]
}

function Resolve-Credential {
    param($Settings, [string]$Override = '')

    $authS = ConvertTo-Trimmed (Get-SettingsValue $Settings 'env.ANTHROPIC_AUTH_TOKEN')
    $keyS  = ConvertTo-Trimmed (Get-SettingsValue $Settings 'env.ANTHROPIC_API_KEY')
    $authE = ConvertTo-Trimmed (Get-EnvOrEmpty 'ANTHROPIC_AUTH_TOKEN')
    $keyE  = ConvertTo-Trimmed (Get-EnvOrEmpty 'ANTHROPIC_API_KEY')

    if ($authS -ne '' -and $authE -ne '' -and $authS -cne $authE) { Add-Warning 'env-shadowed' 'ANTHROPIC_AUTH_TOKEN' }
    if ($keyS  -ne '' -and $keyE  -ne '' -and $keyS  -cne $keyE)  { Add-Warning 'env-shadowed' 'ANTHROPIC_API_KEY' }

    if ($authS -ne '') { $auth = $authS; $authFrom = 'settings' } else { $auth = $authE; $authFrom = 'env' }
    if ($keyS  -ne '') { $key  = $keyS;  $keyFrom  = 'settings' } else { $key  = $keyE;  $keyFrom  = 'env' }

    $value = ''
    $scheme = ''
    $from = ''

    switch ($Override) {
        'bearer' {
            if ($auth -eq '') {
                Stop-WithError 3 'missing-credential' '--auth-scheme bearer was given but ANTHROPIC_AUTH_TOKEN is not set'
            }
            if ($key -ne '' -and $key -cne $auth) {
                Add-Warning 'redundant-credentials' 'ANTHROPIC_API_KEY is set but not used'
            }
            $value = $auth; $scheme = 'bearer'; $from = $authFrom
        }
        'x-api-key' {
            if ($key -eq '') {
                Stop-WithError 3 'missing-credential' '--auth-scheme x-api-key was given but ANTHROPIC_API_KEY is not set'
            }
            if ($auth -ne '' -and $auth -cne $key) {
                Add-Warning 'redundant-credentials' 'ANTHROPIC_AUTH_TOKEN is set but not used'
            }
            $value = $key; $scheme = 'x-api-key'; $from = $keyFrom
        }
        '' {
            if ($auth -ne '' -and $key -ne '') {
                if ($auth -ceq $key) {
                    Add-Warning 'redundant-credentials' 'both token variables hold the same value'
                    $value = $auth; $scheme = 'bearer'; $from = $authFrom
                } else {
                    Stop-WithError 4 'auth-ambiguity' @'
Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY are set with different values.
Claude Code sends both Authorization: Bearer and X-Api-Key, but Claude Desktop
can send only one (inferenceGatewayAuthScheme). Choose explicitly:
  --auth-scheme bearer     (use ANTHROPIC_AUTH_TOKEN)
  --auth-scheme x-api-key  (use ANTHROPIC_API_KEY)
'@
                }
            } elseif ($auth -ne '') {
                $value = $auth; $scheme = 'bearer'; $from = $authFrom
            } elseif ($key -ne '') {
                $value = $key; $scheme = 'x-api-key'; $from = $keyFrom
            } else {
                Stop-WithError 3 'missing-credential' @"
Neither ANTHROPIC_AUTH_TOKEN nor ANTHROPIC_API_KEY is set in $($script:State.Settings).
Claude Code is not configured for a gateway on this machine, so there is
nothing to migrate.
"@
            }
        }
        default { Stop-WithError 2 'usage' "unknown auth scheme: $Override" }
    }

    if ($from -eq 'env') {
        if ($scheme -eq 'bearer') { $wanted = 'ANTHROPIC_AUTH_TOKEN' } else { $wanted = 'ANTHROPIC_API_KEY' }
        Stop-WithError 3 'token-not-in-settings' @"
The credential was found only in the environment, not in $($script:State.Settings).
Claude Desktop does not inherit your shell environment, so its credential
helper could not read it later. Add it to the env block of that file:

  { "env": { "ANTHROPIC_BASE_URL": "...", "$wanted": "..." } }

This tool never writes to that file.
"@
    }

    $script:Core.Token       = $value
    $script:Core.AuthScheme  = $scheme
    $script:Core.TokenSource = $from
    $script:State.Token      = $value
}

# --- models ---------------------------------------------------------------

function New-ModelEntry {
    param([string]$Id)
    return [ordered]@{
        name                  = $Id
        labelOverride         = ''
        supports1m            = ''
        prefer1m              = ''
        anthropicFamilyTier   = ''
        isFamilyDefault       = ''
        behavesAs             = ''
        maxEffort             = ''
    }
}

function Find-ModelIndex {
    param([string]$Id)
    for ($i = 0; $i -lt $script:Core.Models.Count; $i++) {
        if ($script:Core.Models[$i].name -ceq $Id) { return $i }
    }
    return -1
}

function Add-ModelIfAbsent {
    param([string]$Id)

    # Claude Code's [1m] selector suffix is not part of a provider model ID
    # (SPEC 5.3a). PowerShell's -match is case-insensitive, so [1M] is caught too.
    $clean = $Id
    $oneshot = $false
    if ($Id -match '\[1m\]$') {
        $clean = $Id.Substring(0, $Id.Length - 4)
        $oneshot = $true
    }

    $idx = Find-ModelIndex $clean
    if ($idx -ge 0) {
        if ($oneshot) { $script:Core.Models[$idx].supports1m = 'true' }
        return $idx
    }
    Assert-Clean $clean 'model id'
    [void]$script:Core.Models.Add((New-ModelEntry $clean))
    $idx = $script:Core.Models.Count - 1
    if ($oneshot) {
        $script:Core.Models[$idx].supports1m = 'true'
        Add-Warning 'model-1m-suffix-stripped' $clean
    }
    return $idx
}

# Claude Desktop discards model IDs that do not reference an Anthropic model,
# and the mere presence of inferenceModels suppresses discovery, so an
# all-discarded list leaves the picker empty (SPEC 5.3b).
function Apply-AnthropicFilter {
    if ($script:Core.Models.Count -eq 0) { return }

    $kept = New-Object System.Collections.ArrayList
    foreach ($m in $script:Core.Models) {
        if ($m.name.ToLowerInvariant().Contains('claude')) {
            [void]$kept.Add($m)
        } else {
            Add-Warning 'model-not-anthropic' $m.name
        }
    }

    if ($kept.Count -eq 0) {
        $script:Core.Models.Clear()
        Add-Warning 'models-discovery-fallback' `
            'no configured model references an Anthropic model; leaving the list unset so Claude Desktop can discover models'
        return
    }

    $script:Core.Models = $kept
}

function Read-MappingFile {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-WithError 3 'mapping-missing' "model mapping file not found: $Path"
    }
    try {
        $doc = Read-JsonFile $Path
    } catch {
        Stop-WithError 3 'mapping-invalid' "$Path is not valid JSON"
    }
    $sv = Get-Prop $doc 'schemaVersion'
    if ("$sv" -cne '1') { Stop-WithError 3 'mapping-invalid' "$Path must set schemaVersion to 1" }

    $items = Get-Prop $doc 'models'
    if ($null -eq $items) { return }
    foreach ($item in @($items)) {
        $id = Get-Prop $item 'id'
        if ([string]::IsNullOrEmpty([string]$id)) { continue }
        $fields = [ordered]@{
            labelOverride       = [string](Get-Prop $item 'labelOverride')
            supports1m          = [string](Get-Prop $item 'supports1m')
            prefer1m            = [string](Get-Prop $item 'prefer1m')
            anthropicFamilyTier = [string](Get-Prop $item 'anthropicFamilyTier')
            isFamilyDefault     = [string](Get-Prop $item 'isFamilyDefault')
            behavesAs           = [string](Get-Prop $item 'behavesAs')
            maxEffort           = [string](Get-Prop $item 'maxEffort')
        }
        [void]$script:Core.MapIds.Add([string]$id)
        [void]$script:Core.MapFields.Add($fields)
    }
}

function Build-Models {
    param($Settings)

    $script:Core.Models.Clear()

    $script:Core.DefaultModel = Resolve-Pick $Settings 'env.ANTHROPIC_MODEL' 'ANTHROPIC_MODEL'
    if ($script:Core.DefaultModel -eq '') {
        $script:Core.DefaultModel = ConvertTo-Trimmed (Get-SettingsValue $Settings 'model')
    }
    if ($script:Core.DefaultModel -ne '') {
        [void](Add-ModelIfAbsent $script:Core.DefaultModel)
    }

    $tiers = @(
        @{ name = 'opus';   env = 'ANTHROPIC_DEFAULT_OPUS_MODEL' },
        @{ name = 'sonnet'; env = 'ANTHROPIC_DEFAULT_SONNET_MODEL' },
        @{ name = 'haiku';  env = 'ANTHROPIC_DEFAULT_HAIKU_MODEL' },
        @{ name = 'fable';  env = 'ANTHROPIC_DEFAULT_FABLE_MODEL' }
    )
    foreach ($t in $tiers) {
        $val = Resolve-Pick $Settings ("env." + $t.env) $t.env
        if ($val -eq '') { continue }
        $idx = Add-ModelIfAbsent $val
        $script:Core.Models[$idx].anthropicFamilyTier = $t.name
        $script:Core.Models[$idx].isFamilyDefault     = 'true'
        # Which model each tier named, before de-duplication (SPEC 13.5).
        if (-not $script:MagpieTierModels) { $script:MagpieTierModels = @{} }
        $script:MagpieTierModels[$t.name] = $script:Core.Models[$idx].name
    }

    for ($i = 0; $i -lt $script:Core.MapIds.Count; $i++) {
        $id = $script:Core.MapIds[$i]
        $idx = Find-ModelIndex $id
        if ($idx -lt 0) {
            if (-not $script:Core.AllowUnlisted) {
                Stop-WithError 3 'mapping-unlisted' @"
Model mapping names '$id', which is not present in the Claude Code configuration.
Set it in ANTHROPIC_MODEL or ANTHROPIC_DEFAULT_*_MODEL, or pass
--allow-unlisted-models to add it anyway.
"@
            }
            $idx = Add-ModelIfAbsent $id
            Add-Warning 'mapping-added-model' $id
        }
        $f = $script:Core.MapFields[$i]
        foreach ($k in @('labelOverride','supports1m','prefer1m','anthropicFamilyTier','isFamilyDefault','behavesAs','maxEffort')) {
            if ($f[$k] -ne '') { $script:Core.Models[$idx][$k] = $f[$k] }
        }
    }

    if ($script:Core.Models.Count -eq 0) {
        Add-Warning 'no-model-config' 'no model information in the Claude Code configuration'
        return
    }

    # The magpie bridge exports to a client with no such filter (SPEC 13.4).
    if (-not $script:MagpieNoFilter) { Apply-AnthropicFilter }
    if ($script:Core.Models.Count -eq 0) { return }

    $hasTier = $false
    foreach ($m in $script:Core.Models) { if ($m.anthropicFamilyTier -ne '') { $hasTier = $true; break } }
    if ($script:Core.Discovery -eq 'false' -and $hasTier) {
        Add-Warning 'discovery-off-with-tiers' 'tier aliases are documented as requiring model discovery'
    }
}

# --- JSON shapes ----------------------------------------------------------

function Get-ModelsArray {
    $out = @()
    foreach ($m in $script:Core.Models) {
        $o = [ordered]@{ name = $m.name }
        if ($m.labelOverride       -ne '') { $o.labelOverride       = $m.labelOverride }
        if ($m.supports1m          -ne '') { $o.supports1m          = ($m.supports1m -eq 'true') }
        if ($m.prefer1m            -ne '') { $o.prefer1m            = ($m.prefer1m -eq 'true') }
        if ($m.anthropicFamilyTier -ne '') { $o.anthropicFamilyTier = $m.anthropicFamilyTier }
        if ($m.isFamilyDefault     -ne '') { $o.isFamilyDefault     = ($m.isFamilyDefault -eq 'true') }
        if ($m.behavesAs           -ne '') { $o.behavesAs           = $m.behavesAs }
        if ($m.maxEffort           -ne '') { $o.maxEffort           = $m.maxEffort }
        $out += $o
    }
    return $out
}

function Get-PlanObject {
    $plan = [ordered]@{
        ok             = $true
        baseUrl        = $script:Core.BaseUrl
        baseUrlHost    = $script:Core.BaseHost
        authScheme     = $script:Core.AuthScheme
        tokenSource    = $script:Core.TokenSource
        tokenLength    = (Get-ByteLength $script:Core.Token)
        credentialKind = 'helper-script'
        deploymentMode = $script:Core.DeploymentMode
        helperTtlSec   = [int]$script:Core.HelperTtl
    }
    if ($script:Core.Discovery -ne '') {
        $plan.modelDiscoveryEnabled = ($script:Core.Discovery -eq 'true')
    }
    $plan.models   = @(Get-ModelsArray)
    $plan.warnings = @(Get-WarningObjects)
    $plan.errors   = @()
    return $plan
}

function Get-ConfigObject {
    $cfg = [ordered]@{
        inferenceProvider               = 'gateway'
        inferenceGatewayBaseUrl         = $script:Core.BaseUrl
        inferenceGatewayAuthScheme      = $script:Core.AuthScheme
        inferenceCredentialKind         = 'helper-script'
        inferenceCredentialHelperWindows = $script:State.HelperCmd
        inferenceCredentialHelperTtlSec = [int]$script:Core.HelperTtl
    }
    if ($script:Core.Models.Count -gt 0) {
        $cfg.inferenceModels = @(Get-ModelsArray)
    }
    if ($script:Core.Discovery -ne '') {
        $cfg.modelDiscoveryEnabled = ($script:Core.Discovery -eq 'true')
    }
    $cfg.deploymentMode = $script:Core.DeploymentMode
    return $cfg
}

function Invoke-Core {
    param([string]$Override = '')

    if (-not (Test-Path -LiteralPath $script:State.Settings -PathType Leaf)) {
        Stop-WithError 3 'settings-missing' @"
$($script:State.Settings) was not found. This tool migrates an existing Claude Code
gateway configuration; there is nothing to read. Create that file first.
"@
    }

    $settings = Read-SettingsDocument

    $rawUrl = Resolve-Pick $settings 'env.ANTHROPIC_BASE_URL' 'ANTHROPIC_BASE_URL'
    Test-BaseUrl $rawUrl

    Resolve-Credential $settings $Override

    Read-MappingFile $script:Core.MappingPath
    Build-Models $settings
}
