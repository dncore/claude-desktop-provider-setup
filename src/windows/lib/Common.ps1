# Common helpers, Windows implementation.
# Windows PowerShell 5.1 compatible. Do not use PS7-only syntax.

Set-StrictMode -Version 2.0

$script:ToolName    = 'claude-desktop-provider-setup'
$script:ToolVersion = '0.1.0'

$script:State = @{
    Home        = $env:USERPROFILE
    Settings    = Join-Path $env:USERPROFILE '.claude\settings.json'
    AppData     = Join-Path $env:LOCALAPPDATA 'Claude-3p'
    Library     = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
    StateDir    = Join-Path $env:LOCALAPPDATA 'claude-desktop-provider-setup'
    BackupRoot  = Join-Path $env:LOCALAPPDATA 'claude-desktop-provider-setup\backups'
    HelperDir   = Join-Path $env:LOCALAPPDATA 'claude-desktop-provider-setup\helper'
    Warnings    = New-Object System.Collections.ArrayList
    PlanMode    = $false
    Verbose     = $false
    DryRun      = $false
    Token       = ''
}

$script:State.StateFile  = Join-Path $script:State.StateDir 'state.json'
$script:State.HelperCmd  = Join-Path $script:State.HelperDir 'credential-helper.cmd'
$script:State.HelperPs1  = Join-Path $script:State.HelperDir 'credential-helper.ps1'
$script:State.DataRoot   = $env:LOCALAPPDATA
$script:State.AppLog     = ''

function Get-State { return $script:State }

# An MSIX-packaged application gets its own view of %LOCALAPPDATA%: writes and
# reads are redirected to
#   %LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Local\
# A normal process writing to %LOCALAPPDATA%\Claude-3p writes to the real
# directory, which the packaged app never reads. Confirmed on Windows 10 with
# Claude 6.28899.6.0 (MSIX): the app's data and logs appear only under
# LocalCache\Local, and %LOCALAPPDATA%\Claude-3p is never created.
#
# CDS_DATA_ROOT overrides detection; the test suites use it to stay inside a
# disposable profile.
function Get-ClaudeDataRoot {
    if ($env:CDS_DATA_ROOT) { return $env:CDS_DATA_ROOT }
    $pfn = $null
    try {
        $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) { $pfn = $pkg.PackageFamilyName }
    } catch {
        # Get-AppxPackage can be unavailable or blocked; fall back to the real path.
    }
    if ($pfn) {
        return (Join-Path $env:LOCALAPPDATA "Packages\$pfn\LocalCache\Local")
    }
    return $env:LOCALAPPDATA
}

function Initialize-ClaudePaths {
    $root = Get-ClaudeDataRoot
    $script:State.DataRoot = $root
    $script:State.AppData  = Join-Path $root 'Claude-3p'
    $script:State.Library  = Join-Path $root 'Claude-3p\configLibrary'
    $script:State.AppLog   = Join-Path $root 'Claude\logs\main.log'
}

function Initialize-OutputEncoding {
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    } catch {
        # A console that refuses the change still works; nothing depends on it.
    }
}

function ConvertTo-Redacted {
    param([string]$Text)
    $t = $script:State.Token
    if ([string]::IsNullOrEmpty($t)) { return $Text }
    if ($null -eq $Text) { return '' }
    $out = $Text.Replace($t, '<redacted>')
    if ($t.Length -ge 8) {
        $out = $out.Replace($t.Substring(0, 8), '<redacted>')
    }
    return $out
}

function Write-Info {
    param([string]$Text = '')
    [Console]::Out.WriteLine((ConvertTo-Redacted $Text))
}

function Write-Note {
    param([string]$Text = '')
    [Console]::Out.WriteLine('  ' + (ConvertTo-Redacted $Text))
}

function Write-DebugLine {
    param([string]$Text)
    if ($script:State.Verbose) {
        [Console]::Error.WriteLine('debug: ' + (ConvertTo-Redacted $Text))
    }
}

function Add-Warning {
    param([string]$Kind, [string]$Detail = '')
    [void]$script:State.Warnings.Add(@{ kind = $Kind; detail = $Detail })
    $suffix = ''
    if ($Detail) { $suffix = ' (' + (ConvertTo-Redacted $Detail) + ')' }
    [Console]::Error.WriteLine('warning: ' + (ConvertTo-Redacted $Kind) + $suffix)
}

function Stop-WithError {
    param([int]$Code, [string]$Kind, [string]$Message)
    [Console]::Error.WriteLine('error: ' + (ConvertTo-Redacted $Kind) + ': ' + (ConvertTo-Redacted $Message))
    if ($script:State.PlanMode) {
        $plan = [ordered]@{
            ok       = $false
            errors   = @(@{ kind = $Kind; code = $Code })
            warnings = @(Get-WarningObjects)
        }
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $plan -Depth 10 -Compress))
    }
    exit $Code
}

function Get-WarningObjects {
    $list = @()
    foreach ($w in $script:State.Warnings) {
        if ($w.detail) { $list += [ordered]@{ kind = $w.kind; detail = $w.detail } }
        else           { $list += [ordered]@{ kind = $w.kind } }
    }
    return $list
}

# Case-sensitive property lookup. PowerShell's normal member access is
# case-insensitive, which would diverge from the macOS implementation reading
# the same JSON, so every read of a user file goes through this.
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) {
            if ([string]$k -ceq $Name) { return $Object[$k] }
        }
        return $null
    }
    foreach ($p in $Object.PSObject.Properties) {
        if ($p.Name -ceq $Name) { return $p.Value }
    }
    return $null
}

function Get-EnvOrEmpty {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v) { return '' }
    return $v
}

function ConvertTo-Trimmed {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Trim()
}

function Get-ByteLength {
    param([string]$Text)
    return [System.Text.Encoding]::UTF8.GetByteCount($Text)
}

function Assert-Clean {
    param([string]$Value, [string]$Label)
    if ($Value -match "[`r`n]") { Stop-WithError 3 'invalid-value' "$Label contains a newline" }
    foreach ($ch in $Value.ToCharArray()) {
        if ([int]$ch -lt 32 -and $ch -ne "`t") {
            Stop-WithError 3 'invalid-value' "$Label contains a control character"
        }
    }
}

function Test-ConfigId {
    param([string]$Id)
    return ($Id -cmatch '^[a-f0-9-]{36}$')
}

function New-ConfigId {
    return ([guid]::NewGuid().ToString('D').ToLowerInvariant())
}

# Write text as UTF-8 without a BOM. Windows PowerShell's -Encoding UTF8 emits a
# BOM, which makes JSON.parse fail in the consumer, so this must not be used.
function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-JsonFile {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

# Convert a PSCustomObject/hashtable tree into an ordered hashtable so that
# ConvertTo-Json emits a stable shape.
function ConvertTo-OrderedMap {
    param($Object)
    if ($null -eq $Object) { return $null }
    $map = [ordered]@{}
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) { $map[$k] = $Object[$k] }
        return $map
    }
    foreach ($p in $Object.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}

function Find-ClaudeApp {
    # Returns @{ Path; Launch; Version; Kind } or $null.
    #
    # CDS_APP_PATH overrides detection. The lifecycle suites use it so they can
    # run on a machine (or CI runner) with no Claude Desktop installed.
    #
    # The current official Windows build installs as an MSIX package under
    # C:\Program Files\WindowsApps. That directory is not enumerable by a
    # standard user, so "search the install directory" is not a usable
    # detection strategy on its own. The reliable handle is the app execution
    # alias the package registers, which is on PATH and is also the correct
    # thing to launch.
    if ($env:CDS_APP_PATH) {
        return @{ Path = $env:CDS_APP_PATH; Launch = $env:CDS_APP_PATH; Version = 'test'; Kind = 'test' }
    }

    $alias = Get-Command 'claude-desktop.exe' -ErrorAction SilentlyContinue
    if ($alias -and $alias.Source -and (Test-Path -LiteralPath $alias.Source)) {
        $version = ''
        $kind = 'msix'
        try {
            $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pkg) { $version = [string]$pkg.Version }
        } catch { }
        return @{
            Path    = $alias.Source
            Launch  = $alias.Source
            Version = $version
            Kind    = $kind
        }
    }

    # Classic per-user Squirrel layout, used by older installers.
    if ($env:LOCALAPPDATA) {
        $legacy = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
        if (Test-Path -LiteralPath $legacy) {
            $exe = Get-ChildItem -LiteralPath $legacy -Filter 'claude.exe' -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($exe) {
                return @{
                    Path    = $exe.FullName
                    Launch  = $exe.FullName
                    Version = (Get-ClaudeVersion $exe.FullName)
                    Kind    = 'exe'
                }
            }
        }
    }

    # MSIX installed for another account or without a registered alias.
    try {
        $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $exe = Get-ChildItem -LiteralPath $pkg.InstallLocation -Filter 'claude.exe' -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($exe) {
                return @{
                    Path    = $exe.FullName
                    Launch  = $exe.FullName
                    Version = [string]$pkg.Version
                    Kind    = 'msix'
                }
            }
        }
    } catch {
        # Get-AppxPackage can be unavailable or blocked; treat as not found.
    }
    return $null
}

function Get-ClaudeVersion {
    param([string]$ExePath)
    if (-not $ExePath) { return '' }
    try { return (Get-Item $ExePath).VersionInfo.ProductVersion } catch { return '' }
}
