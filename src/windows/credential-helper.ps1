# managed-by: claude-desktop-provider-setup
#
# Claude Desktop credential helper (Windows).
#
# Contract: claude.com/docs/third-party/claude-desktop/credential-helper.md
#   - stdout carries the token and nothing else
#   - stderr carries diagnostics only
#   - exit 0 on success
#
# This script holds no credential. It reads the user's existing Claude Code
# settings on every invocation, so a rotated token is picked up on the next run
# without reinstalling or restarting Claude Desktop.
#
# It is launched by credential-helper.cmd, which supplies
# -NoProfile -NonInteractive -ExecutionPolicy Bypass so that a Restricted
# execution policy, the default on some Windows client builds, does not block
# a local script the user installed deliberately.
#
# The path below was written by the installer as a single-quoted PowerShell
# literal. No argument, environment variable, or working directory can
# redirect it.

$SettingsFile = __CDS_SETTINGS_LITERAL__

$EXIT_GONE      = 3
$EXIT_AMBIGUOUS = 4
$EXIT_UNREADABLE = 6

function Note {
    param([string]$Text)
    [Console]::Error.WriteLine("credential-helper: $Text")
}

# Claude Desktop sets CLAUDE_HELPER_CONTEXT so a helper can decide whether
# interactive sign-in is acceptable. This helper never prompts, and it stays
# silent on success so Desktop's diagnostics log is not filled with one line
# per turn. The context is reported only when something fails.

if ([string]::IsNullOrEmpty($SettingsFile)) {
    Note 'no settings path is configured; reinstall the helper'
    exit $EXIT_UNREADABLE
}

if (-not (Test-Path -LiteralPath $SettingsFile)) {
    Note "settings file not found: $SettingsFile"
    exit $EXIT_UNREADABLE
}

$item = Get-Item -LiteralPath $SettingsFile -Force
if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    Note "refusing to follow a link at $SettingsFile"
    exit $EXIT_UNREADABLE
}

try {
    $raw = [System.IO.File]::ReadAllText($SettingsFile, [System.Text.Encoding]::UTF8)
} catch {
    Note "settings file is not readable: $SettingsFile"
    exit $EXIT_UNREADABLE
}

try {
    $doc = $raw | ConvertFrom-Json
} catch {
    Note 'settings file is not valid JSON'
    exit $EXIT_GONE
}

# Case-sensitive lookup: PowerShell member access is case-insensitive, which
# would not match what Claude Code reads from the same file.
function Read-Key {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return '' }
    $env_node = $null
    foreach ($p in $Object.PSObject.Properties) {
        if ($p.Name -ceq 'env') { $env_node = $p.Value; break }
    }
    if ($null -eq $env_node) { return '' }
    foreach ($p in $env_node.PSObject.Properties) {
        if ($p.Name -ceq $Name) {
            if ($null -eq $p.Value) { return '' }
            return ([string]$p.Value).Trim()
        }
    }
    return ''
}

$auth = Read-Key $doc 'ANTHROPIC_AUTH_TOKEN'
$key  = Read-Key $doc 'ANTHROPIC_API_KEY'

if ($auth -ne '' -and $key -ne '' -and $auth -cne $key) {
    Note 'both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY are set with different values;'
    Note 'Claude Desktop can send only one. Re-run the installer with --auth-scheme to choose.'
    exit $EXIT_AMBIGUOUS
}

if ($auth -ne '') {
    [Console]::Out.Write($auth)
    exit 0
}

if ($key -ne '') {
    [Console]::Out.Write($key)
    exit 0
}

Note "neither ANTHROPIC_AUTH_TOKEN nor ANTHROPIC_API_KEY is set in $SettingsFile"
Note "context=$($env:CLAUDE_HELPER_CONTEXT)"
exit $EXIT_GONE
