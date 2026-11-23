# Lifecycle test, Windows.
#
# Exercises install, update, verify, backup and uninstall against a synthetic
# profile: a fake Claude Desktop executable, a configuration library that
# already holds two other configurations, and a Claude Code settings file with
# a gateway configuration.
#
# This is a local script test. It does not launch Claude Desktop, so it proves
# the tool's file handling, not that the real app accepts the result. See
# docs/architecture.md for what each level of testing covers.

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Cli  = Join-Path $Root 'src\windows\Cli.ps1'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$Script:Pass = 0
$Script:Fail = 0
$Script:Failed = New-Object System.Collections.ArrayList

function Ok        { $Script:Pass++ }
function Bad       { param([string]$M) $Script:Fail++; [void]$Script:Failed.Add("  - $M"); Write-Host "FAIL: $M" }
function Assert-Eq {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { Ok } else { Bad "$Label expected [$Expected] got [$Actual]" }
}
function Assert-File      { param([string]$L,[string]$P) if (Test-Path -LiteralPath $P) { Ok } else { Bad "$L missing file $P" } }
function Assert-NoFile    { param([string]$L,[string]$P) if (-not (Test-Path -LiteralPath $P)) { Ok } else { Bad "$L should not exist: $P" } }
function Assert-Contains  { param([string]$L,[string]$Hay,[string]$Needle) if ($Hay.Contains($Needle)) { Ok } else { Bad "$L output does not contain [$Needle]" } }

function Get-JsonProp {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $doc = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { return '' }
    $v = $doc.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
    if (-not $v) { return '' }
    if ($null -eq $v.Value) { return '' }
    return [string]$v.Value
}

$fakeHome = Join-Path ([System.IO.Path]::GetTempPath()) ("cds-life-" + [guid]::NewGuid().ToString('N'))
$local    = Join-Path $fakeHome 'Local'
# Simulate MSIX virtualization: the app's data root deliberately differs from
# LOCALAPPDATA, which is what forces path resolution to happen after module
# load. A module that captures the library path at dot-source time passes when
# the two are equal and fails here.
$dataRoot = Join-Path $local 'virtualized'
$lib      = Join-Path $dataRoot 'Claude-3p\configLibrary'
$stateDir = Join-Path $local 'claude-desktop-provider-setup'
$appDir   = Join-Path $local 'AnthropicClaude'
$claudeDir = Join-Path $fakeHome '.claude'

function Run-Cli {
    param([string[]]$Arguments)
    $o = Join-Path $fakeHome 'cli-out.txt'
    $e = Join-Path $fakeHome 'cli-err.txt'
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList (@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"`"$Cli`"") + $Arguments) `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    $out = ''
    if (Test-Path $o) { $out = [System.IO.File]::ReadAllText($o, [System.Text.Encoding]::UTF8) }
    return @{ Code = $proc.ExitCode; Out = $out }
}

try {
    Remove-Item $fakeHome -Recurse -Force -EA SilentlyContinue
    New-Item -ItemType Directory -Force -Path $lib, $appDir, $claudeDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $appDir 'claude.exe'), '', $Utf8)

    $meta = '{"appliedId":"359f288e-c4ec-4dae-a5ea-a47bcaa38438","entries":[' +
            '{"id":"359f288e-c4ec-4dae-a5ea-a47bcaa38438","name":"Default"},' +
            '{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"Team 配置: prod"}]}'
    [System.IO.File]::WriteAllText((Join-Path $lib '_meta.json'), $meta, $Utf8)
    [System.IO.File]::WriteAllText((Join-Path $lib '359f288e-c4ec-4dae-a5ea-a47bcaa38438.json'),
        '{"inferenceGatewayApiKey":"pre-existing","inferenceProvider":"gateway"}', $Utf8)
    [System.IO.File]::WriteAllText((Join-Path $lib 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json'),
        '{"inferenceProvider":"gateway"}', $Utf8)

    $settings = @'
{ "model": "top-level-ignored",
  "env": {
    "ANTHROPIC_BASE_URL": "https://gw.example.com/api/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "fake-token-1234567890",
    "ANTHROPIC_MODEL": "gw-default",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gw-opus",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gw-sonnet"
  },
  "permissions": { "allow": ["Bash"] } }
'@
    $settingsPath = Join-Path $claudeDir 'settings.json'
    [System.IO.File]::WriteAllText($settingsPath, $settings, $Utf8)

    # Redirect the child's whole profile so the test cannot touch the real one.
    $savedProfile   = $env:USERPROFILE
    $savedLocal     = $env:LOCALAPPDATA
    $savedDataRoot  = $env:CDS_DATA_ROOT
    $savedAppPath   = $env:CDS_APP_PATH
    $env:USERPROFILE  = $fakeHome
    $env:LOCALAPPDATA = $local
    $env:CDS_NO_PAUSE = '1'
    # Keep the tool inside the disposable profile and off the machine's real
    # Claude Desktop / MSIX package, if any.
    $env:CDS_DATA_ROOT = $dataRoot
    $env:CDS_APP_PATH  = (Join-Path $appDir 'claude.exe')

    try {
        # --- install -----------------------------------------------------
        $r = Run-Cli @('install')
        Assert-Eq 'install exit' '0' "$($r.Code)"
        Assert-Contains 'install reports config id' $r.Out 'config id:'

        $id = Get-JsonProp (Join-Path $stateDir 'state.json') 'configId'
        if ($id) { Ok } else { Bad 'state has no configId' }

        Assert-File 'configuration written' (Join-Path $lib "$id.json")
        Assert-Eq 'appliedId is ours' $id (Get-JsonProp (Join-Path $lib '_meta.json') 'appliedId')

        $metaDoc = [System.IO.File]::ReadAllText((Join-Path $lib '_meta.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Eq 'three entries after install' '3' "$(@($metaDoc.entries).Count)"
        Assert-Eq 'existing entry name preserved' 'Team 配置: prod' ([string]$metaDoc.entries[1].name)
        Assert-Eq 'previous config untouched' 'pre-existing' `
            (Get-JsonProp (Join-Path $lib '359f288e-c4ec-4dae-a5ea-a47bcaa38438.json') 'inferenceGatewayApiKey')
        Assert-Eq 'no inline secret in ours' '' (Get-JsonProp (Join-Path $lib "$id.json") 'inferenceGatewayApiKey')
        Assert-Eq 'cli settings untouched' $settings ([System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8))

        # --- helper reads live settings --------------------------------
        $helper = Join-Path $stateDir 'helper\credential-helper.cmd'
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $helper) -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput (Join-Path $fakeHome 'h1.txt') -RedirectStandardError (Join-Path $fakeHome 'h1e.txt')
        $h1 = [System.IO.File]::ReadAllText((Join-Path $fakeHome 'h1.txt'), [System.Text.Encoding]::UTF8).Trim()
        Assert-Eq 'helper returns token' 'fake-token-1234567890' $h1
        Assert-Eq 'helper exit' '0' "$($p.ExitCode)"

        [System.IO.File]::WriteAllText($settingsPath, $settings.Replace('fake-token-1234567890', 'rotated-token-XYZ'), $Utf8)
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $helper) -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput (Join-Path $fakeHome 'h2.txt') -RedirectStandardError (Join-Path $fakeHome 'h2e.txt')
        $h2 = [System.IO.File]::ReadAllText((Join-Path $fakeHome 'h2.txt'), [System.Text.Encoding]::UTF8).Trim()
        Assert-Eq 'helper returns rotated token' 'rotated-token-XYZ' $h2

        # --- verify ------------------------------------------------------
        $r = Run-Cli @('verify')
        Assert-Eq 'verify exit' '0' "$($r.Code)"
        Assert-Contains 'verify reports ok' $r.Out 'verify: OK'

        # --- update reuses the id ---------------------------------------
        $r = Run-Cli @('update')
        Assert-Eq 'update exit' '0' "$($r.Code)"
        Assert-Eq 'update reuses the id' $id (Get-JsonProp (Join-Path $stateDir 'state.json') 'configId')
        $metaDoc = [System.IO.File]::ReadAllText((Join-Path $lib '_meta.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Eq 'still three entries' '3' "$(@($metaDoc.entries).Count)"

        # --- backup ------------------------------------------------------
        $r = Run-Cli @('backup')
        Assert-Eq 'backup exit' '0' "$($r.Code)"
        $r = Run-Cli @('list-backups')
        Assert-Contains 'backup is listed' $r.Out '20'

        # --- uninstall ---------------------------------------------------
        $r = Run-Cli @('uninstall')
        Assert-Eq 'uninstall exit' '0' "$($r.Code)"
        Assert-Eq 'appliedId restored' '359f288e-c4ec-4dae-a5ea-a47bcaa38438' `
            (Get-JsonProp (Join-Path $lib '_meta.json') 'appliedId')
        $metaDoc = [System.IO.File]::ReadAllText((Join-Path $lib '_meta.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Eq 'entries back to two' '2' "$(@($metaDoc.entries).Count)"
        Assert-NoFile 'our configuration removed' (Join-Path $lib "$id.json")
        Assert-NoFile 'helper removed' $helper
        Assert-NoFile 'state removed' (Join-Path $stateDir 'state.json')
        Assert-Eq 'pre-existing config still untouched' 'pre-existing' `
            (Get-JsonProp (Join-Path $lib '359f288e-c4ec-4dae-a5ea-a47bcaa38438.json') 'inferenceGatewayApiKey')
        Assert-Eq 'cli settings still untouched' $settings.Replace('fake-token-1234567890', 'rotated-token-XYZ') `
            ([System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8))
    }
    finally {
        $env:USERPROFILE  = $savedProfile
        $env:LOCALAPPDATA = $savedLocal
        $env:CDS_DATA_ROOT = $savedDataRoot
        $env:CDS_APP_PATH  = $savedAppPath
    }
}
finally {
    Remove-Item $fakeHome -Recurse -Force -EA SilentlyContinue
}

Write-Host ''
Write-Host "$Script:Pass passed, $Script:Fail failed"
if ($Script:Fail -ne 0) {
    Write-Host 'failed assertions:'
    foreach ($l in $Script:Failed) { Write-Host $l }
    exit 1
}
exit 0
