# Command-line entry point, Windows.
# Parses arguments, then dispatches. All behaviour lives in the modules.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgumentList
)

# $PSCommandPath is <root>\src\windows\Cli.ps1, so the repository root is three
# levels up.
$script:Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

. (Join-Path $script:Root 'src\windows\lib\Common.ps1')
Initialize-OutputEncoding
. (Join-Path $script:Root 'src\windows\lib\Core.ps1')
. (Join-Path $script:Root 'src\windows\ConfigManager.ps1')
. (Join-Path $script:Root 'src\windows\BackupManager.ps1')
. (Join-Path $script:Root 'src\windows\Setup.ps1')

# The configuration library lives under the app's own view of %LOCALAPPDATA%,
# which differs for an MSIX install. Resolve that before anything reads paths.
Initialize-ClaudePaths

$script:Command      = 'install'
$script:AuthOverride = ''
$script:ConfigName   = ''
$script:Restart      = $false
$script:Purge        = $false
$script:Positional   = ''
$script:RestoreArg   = ''

if ($null -eq $ArgumentList) { $ArgumentList = @() }

function Show-Usage {
    Write-Info @'
claude-desktop-provider-setup - point Claude Desktop at the same gateway as Claude Code

USAGE
  install.bat [command] [options]

COMMANDS
  install       Read %USERPROFILE%\.claude\settings.json and configure Claude Desktop (default)
  update        Re-apply the configuration after the Claude Code settings changed
  verify        Check that the installed configuration is intact and usable
  diagnose      Print a redacted report; safe to paste into an issue
  backup        Take a backup of the Claude Desktop configuration library
  restore       Restore a backup by timestamp, or the most recent one
  list-backups  List available backups
  uninstall     Remove only what this tool created
  plan          Print the resolved plan as JSON and change nothing

OPTIONS
  --auth-scheme bearer|x-api-key  Choose when both token variables are set
  --mapping <path>                Model mapping file
  --allow-unlisted-models         Let the mapping add model IDs absent from Claude Code
  --allow-http                    Permit an http base URL (loopback testing only)
  --no-model-discovery            Emit modelDiscoveryEnabled=false
  --require-model-discovery       Emit modelDiscoveryEnabled=true
  --deployment-mode 3p|any        Hide the Claude.ai sign-in (default: 3p)
  --helper-ttl <seconds>          Credential helper cache lifetime (default: 900)
  --config-name <name>            Name shown in the Claude Desktop config picker
  --dry-run                       Same as `plan`
  --restart                       Close and relaunch Claude Desktop afterwards
  --purge                         With uninstall: also delete backups and state
  --verbose                       Extra diagnostics on stderr
  -h, --help                      Show this help

EXIT CODES
  0 ok   2 usage   3 unusable config   4 ambiguity   5 environment   6 write/verify   7 helper
'@
}

function Get-ArgValue {
    param([string[]]$List, [int]$Index, [string]$Option)
    if ($Index + 1 -ge $List.Count) { Stop-WithError 2 'usage' "$Option needs a value" }
    return $List[$Index + 1]
}

function Read-Arguments {
    $commands = @('install','update','verify','diagnose','backup','restore','list-backups','uninstall','plan')
    $i = 0
    while ($i -lt $ArgumentList.Count) {
        $a = $ArgumentList[$i]

        if ($commands -contains $a) { $script:Command = $a; $i++; continue }
        if ($a -ceq '--print-plan' -or $a -ceq '--dry-run') { $script:Command = 'plan'; $i++; continue }

        if ($a -ceq '--allow-unlisted-models')   { $script:Core.AllowUnlisted = $true }
        elseif ($a -ceq '--allow-http')          { $script:Core.AllowHttp = $true }
        elseif ($a -ceq '--no-model-discovery')  { $script:Core.Discovery = 'false' }
        elseif ($a -ceq '--require-model-discovery') { $script:Core.Discovery = 'true' }
        elseif ($a -ceq '--restart') { $script:Restart = $true }
        elseif ($a -ceq '--purge')   { $script:Purge = $true }
        elseif ($a -ceq '--verbose') { $script:State.Verbose = $true }
        elseif ($a -ceq '-h' -or $a -ceq '--help') { Show-Usage; exit 0 }
        elseif ($a -ceq '--auth-scheme') {
            $v = Get-ArgValue $ArgumentList $i '--auth-scheme'
            if ($v -ne 'bearer' -and $v -ne 'x-api-key') {
                Stop-WithError 2 'usage' '--auth-scheme must be bearer or x-api-key'
            }
            $script:AuthOverride = $v
            $i++
        }
        elseif ($a -ceq '--mapping') {
            $script:Core.MappingPath = Get-ArgValue $ArgumentList $i '--mapping'
            $i++
        }
        elseif ($a -ceq '--deployment-mode') {
            $v = Get-ArgValue $ArgumentList $i '--deployment-mode'
            if ($v -ne '3p' -and $v -ne 'any') {
                Stop-WithError 2 'usage' '--deployment-mode must be 3p or any'
            }
            $script:Core.DeploymentMode = $v
            $i++
        }
        elseif ($a -ceq '--helper-ttl') {
            $v = Get-ArgValue $ArgumentList $i '--helper-ttl'
            $n = 0
            if (-not [int]::TryParse($v, [ref]$n) -or $n -lt 1) {
                Stop-WithError 2 'usage' '--helper-ttl must be a positive integer'
            }
            $script:Core.HelperTtl = $n
            $i++
        }
        elseif ($a -ceq '--config-name') {
            $script:ConfigName = Get-ArgValue $ArgumentList $i '--config-name'
            $i++
        }
        elseif ($a.StartsWith('-')) {
            Stop-WithError 2 'usage' "unknown argument: $a (try --help)"
        }
        else {
            $script:Positional = $a
        }
        $i++
    }
}

function Test-FileIsOurs {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($script:State.StateDir)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($root + $sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $text = [System.IO.File]::ReadAllText($full)
    return $text.Contains('managed-by: claude-desktop-provider-setup')
}

function Invoke-Uninstall {
    Assert-State

    if ($script:State.DryRun) {
        Write-Info "would remove configuration $(Get-StateValue 'configId') and the helper it installed"
        return
    }

    $id = Get-StateValue 'configId'
    $prev = Get-StateValue 'previousAppliedId'
    if (-not $id) { Stop-WithError 6 'state-invalid' 'state.json has no configId' }

    if (Test-Path -LiteralPath $script:State.Library) {
        $backup = New-Backup 'pre-uninstall'
        Write-Note "backup: $backup"
    }

    $result = Remove-Config $id $prev
    if ($result.Changed) { Write-Note "removed configuration $id" }

    foreach ($helper in (Get-StateArray 'helperFiles')) {
        if (Test-FileIsOurs $helper) {
            Remove-Item -LiteralPath $helper -Force
            Write-Note "removed helper $helper"
        } else {
            Add-Warning 'helper-not-ours' "left in place: $helper"
        }
    }

    if ($script:Purge) {
        if (Test-Path -LiteralPath $script:State.StateDir) {
            Remove-Item -LiteralPath $script:State.StateDir -Recurse -Force
            Write-Note "removed $($script:State.StateDir) (state and all backups)"
        }
    } else {
        if (Test-Path -LiteralPath $script:State.StateFile) {
            Remove-Item -LiteralPath $script:State.StateFile -Force
            Write-Note "removed $($script:State.StateFile); backups kept in $($script:State.BackupRoot)"
            Write-Note 'run --purge to delete the backups as well'
        }
    }

    Write-Info ''
    Write-Info "Claude Desktop no longer points at your gateway through this tool."
    Write-Info "Claude Code's own settings were never modified."
    if ($script:Restart) { Restart-App }
}

function Invoke-Main {
    Read-Arguments

    if ($script:Command -eq 'plan') { $script:State.PlanMode = $true }

    if ($script:Positional) {
        if ($script:Command -eq 'restore') { $script:RestoreArg = $script:Positional }
        else { Stop-WithError 2 'usage' "unexpected argument: $script:Positional" }
    }

    if (-not $script:Core.MappingPath) {
        $default = Join-Path $script:Root 'config\model-mapping.json'
        if (Test-Path -LiteralPath $default) { $script:Core.MappingPath = $default }
    }

    switch ($script:Command) {
        'plan' {
            Invoke-Core $script:AuthOverride
            $plan = Get-PlanObject
            [Console]::Out.WriteLine((ConvertTo-Json -InputObject $plan -Depth 10 -Compress))
        }
        'install' { Setup-Install 'install' }
        'update'  { Setup-Install 'update' }
        'verify'  { exit (Setup-Verify) }
        'diagnose' { Setup-Diagnose }
        'backup' {
            Assert-Library
            $b = New-Backup 'manual'
            Write-Note "backup written to $b"
        }
        'list-backups' {
            $list = Get-BackupList
            if ($list.Count -eq 0) { Write-Info 'no backups' } else { foreach ($b in $list) { Write-Info $b } }
        }
        'restore' {
            $target = $script:RestoreArg
            if (-not $target) {
                $target = Get-LatestBackup
                if (-not $target) { Stop-WithError 5 'backup-missing' 'no backups to restore' }
            }
            $restored = Restore-Backup $target
            Write-Note "restored from $restored"
        }
        'uninstall' { Invoke-Uninstall }
        default { Stop-WithError 2 'usage' "unknown command: $($script:Command)" }
    }
}

Invoke-Main
