# Install, update, verify and diagnose, Windows.
# Implements src/common/SPEC.md sections 6-11.

$script:MinBuild = 19041

function ConvertTo-PsSingleQuoted {
    param([string]$Text)
    $escaped = $Text.Replace("'", "''")
    return "'$escaped'"
}

function Test-OsVersion {
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt $script:MinBuild) {
        Stop-WithError 5 'unsupported-os' @"
Windows build $build is too old. Claude Desktop requires Windows 10 build
19041 (version 2004) or later, including Windows 11.
"@
    }
    return $build
}

function Get-AppInfo {
    $a = Find-ClaudeApp
    if (-not $a) { return @{ Path = ''; Launch = ''; Version = ''; Kind = '' } }
    return $a
}

function Assert-App {
    $app = Get-AppInfo
    if (-not $app.Path) {
        Stop-WithError 5 'app-not-installed' @"
Claude Desktop was not found in the usual install locations.

Install it from https://claude.ai/download, launch it once so it creates its
data directory, quit it, and run this installer again.

This tool never downloads or installs Claude Desktop itself.
"@
    }
    return $app
}

function Install-Helper {
    $template = Join-Path $script:Root 'src\windows\credential-helper.ps1'
    $cmdSrc   = Join-Path $script:Root 'src\windows\credential-helper.cmd'
    if (-not (Test-Path -LiteralPath $template)) {
        Stop-WithError 5 'missing-file' "helper template not found: $template"
    }

    Assert-Clean $script:State.Settings 'settings path'
    $literal = ConvertTo-PsSingleQuoted $script:State.Settings

    $content = [System.IO.File]::ReadAllText($template, [System.Text.Encoding]::UTF8)
    if ($content.IndexOf('__CDS_SETTINGS_LITERAL__') -lt 0) {
        Stop-WithError 6 'helper-template' 'the helper template has no substitution point'
    }
    $content = $content.Replace('__CDS_SETTINGS_LITERAL__', $literal)

    Initialize-StateDir
    Write-TextNoBom $script:State.HelperPs1 ($content + "`n")
    Copy-Item -LiteralPath $cmdSrc -Destination $script:State.HelperCmd -Force

    # Parse check before it becomes the live helper.
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $script:State.HelperPs1, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Stop-WithError 6 'helper-syntax' 'generated helper does not parse'
    }
}

function Invoke-Helper {
    $out = ''
    $code = 0
    try {
        $out = & $script:State.HelperCmd 2>$null
        $code = $LASTEXITCODE
    } catch {
        $code = 1
        $out = ''
    }
    $text = ''
    if ($null -ne $out) { $text = (@($out) -join '') }
    return @{ Code = $code; Length = (Get-ByteLength $text.Trim()) }
}

function Setup-Install {
    param([string]$Mode)

    if ($script:State.DryRun) {
        Invoke-Core $script:AuthOverride
        $plan = Get-PlanObject
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $plan -Depth 10 -Compress))
        return
    }

    [void](Test-OsVersion)
    $app = Assert-App
    if (-not (Test-Path -LiteralPath $script:State.Settings)) {
        Stop-WithError 3 'settings-missing' "$($script:State.Settings) was not found. This tool migrates an existing Claude Code gateway configuration; there is nothing to read."
    }
    Assert-Library

    $machine = 'HKLM:\SOFTWARE\Policies\Claude'
    if (Test-Path $machine) { Add-Warning 'managed-policy-present' $machine }

    Invoke-Core $script:AuthOverride

    if ($Mode -eq 'update') {
        Assert-State
        $id = Get-StateValue 'configId'
        $name = Get-StateValue 'configName'
        if (-not $id) { Stop-WithError 6 'state-invalid' 'state.json has no configId' }
        if (-not $name) { $name = 'Migrated from Claude Code' }
        $backup = New-Backup 'pre-update'
    } else {
        $id = ''
        $name = $script:ConfigName
        if (-not $name) { $name = 'Migrated from Claude Code' }
        Assert-Clean $name 'configuration name'
        $backup = New-Backup 'pre-install'
    }
    Write-Note "backup: $backup"

    Install-Helper
    Write-Note "helper: $($script:State.HelperCmd)"

    $cfgJson = ConvertTo-Json -InputObject (Get-ConfigObject) -Depth 10 -Compress
    $result = Install-Config $cfgJson $name $id

    Write-State $result.Id $name $result.Previous $result.MetaExisted @($script:State.HelperCmd)

    Complete-Install
}

function Complete-Install {
    $run = Invoke-Helper
    if ($run.Code -ne 0) {
        Stop-WithError 7 'helper-failed' @"
The credential helper exited $($run.Code) when tested. The configuration was
written, but Claude Desktop will not connect until the helper succeeds.
Run --diagnose for details, or --uninstall to revert.
"@
    }
    if ($run.Length -lt 1) {
        Stop-WithError 7 'helper-failed' 'The credential helper produced no credential.'
    }

    Write-Info ''
    Write-Info 'Claude Desktop is configured.'
    Write-Note "provider:   gateway"
    Write-Note "base URL:   $($script:Core.BaseUrl)"
    Write-Note "auth:       $($script:Core.AuthScheme)"
    Write-Note "credential: helper script (token read from settings.json, $((Get-ByteLength $script:Core.Token)) bytes)"
    Write-Note "models:     $($script:Core.Models.Count) configured"
    foreach ($m in $script:Core.Models) {
        $suffix = ''
        if ($m.anthropicFamilyTier) { $suffix = " ($($m.anthropicFamilyTier))" }
        Write-Note "  - $($m.name)$suffix"
    }
    Write-Note "config id:  $($script:Meta.AppliedId)"

    if ($script:State.Warnings.Count -gt 0) {
        Write-Info ''
        Write-Info 'Warnings:'
        foreach ($w in $script:State.Warnings) { Write-Info "  - $($w.kind): $($w.detail)" }
    }

    Write-Info ''
    Write-Info 'Claude Desktop reads configuration at launch. Restart it to apply.'
    if ($script:Restart) { Restart-App }
}

function Restart-App {
    $app = Get-AppInfo
    $procs = @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        Write-Note 'closing Claude Desktop'
        foreach ($p in $procs) { [void]$p.CloseMainWindow() }
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue).Count -gt 0) {
            Start-Sleep -Milliseconds 250
        }
        if (@(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue).Count -gt 0) {
            Add-Warning 'app-still-running' 'Claude Desktop is still running. Close it from its window, then reopen it.'
            return
        }
    }
    $target = $app.Launch
    if (-not $target) { $target = $app.Path }
    if (-not $target) {
        Add-Warning 'app-launch-failed' 'Claude Desktop executable not found; start it manually.'
        return
    }
    Write-Note 'starting Claude Desktop'
    Start-Process -FilePath $target | Out-Null
}

function Setup-Verify {
    $failures = 0
    [void](Test-OsVersion)
    $app = Assert-App
    Assert-State
    Assert-Library

    $id     = Get-StateValue 'configId'
    $wantUrl = Get-StateValue 'baseUrl'
    $wantScheme = Get-StateValue 'authScheme'

    Write-Info 'verify'
    Write-Note "Claude Desktop: $($app.Path) ($($app.Version))"

    $cfgPath = Join-Path $script:State.Library "$id.json"
    if (Test-Path -LiteralPath $cfgPath) {
        Write-Note "config file: present ($id.json)"
    } else {
        Write-Note "config file: MISSING ($id.json)"
        $failures++
    }

    $cfg = $null
    if (Test-Path -LiteralPath $cfgPath) {
        try { $cfg = Read-JsonFile $cfgPath; Write-Note 'config parses: yes' }
        catch { Write-Note 'config parses: NO'; $failures++ }
    }

    $metaPath = Join-Path $script:State.Library '_meta.json'
    $applied = ''
    if (Test-Path -LiteralPath $metaPath) {
        try { $applied = [string](Get-Prop (Read-JsonFile $metaPath) 'appliedId') } catch { $applied = '' }
    }
    if ($applied -ceq $id) { Write-Note 'applied: yes' }
    else { Write-Note "applied: NO (appliedId is '$applied')"; $failures++ }

    $liveUrl = ''
    $liveScheme = ''
    if ($cfg) {
        $liveUrl = [string](Get-Prop $cfg 'inferenceGatewayBaseUrl')
        $liveScheme = [string](Get-Prop $cfg 'inferenceGatewayAuthScheme')
    }
    if ($liveUrl -ceq $wantUrl) { Write-Note 'base URL: matches' }
    else { Write-Note 'base URL: DRIFTED'; $failures++ }
    if ($liveScheme -ceq $wantScheme) { Write-Note 'auth scheme: matches' }
    else { Write-Note 'auth scheme: DRIFTED'; $failures++ }

    if ($cfg -and $null -ne (Get-Prop $cfg 'inferenceGatewayApiKey')) {
        Write-Note 'no inline secret: NO (inferenceGatewayApiKey is present)'
        $failures++
    } else {
        Write-Note 'no inline secret: yes'
    }

    if (Test-Path -LiteralPath $script:State.HelperCmd) {
        $run = Invoke-Helper
        if ($run.Code -eq 0 -and $run.Length -ge 1) {
            Write-Note "helper: ok (exit 0, credential $($run.Length) bytes)"
        } else {
            Write-Note "helper: FAILED (exit $($run.Code))"
            $failures++
        }
    } else {
        Write-Note 'helper: MISSING'
        $failures++
    }

    if (Test-Path 'HKLM:\SOFTWARE\Policies\Claude') {
        Write-Note 'machine policy: PRESENT — it overrides this configuration'
        $failures++
    } else {
        Write-Note 'machine policy: absent'
    }

    Write-Info ''
    if ($failures -eq 0) { Write-Info 'verify: OK'; return 0 }
    Write-Info "verify: $failures check(s) failed"
    return 6
}

function Setup-Diagnose {
    Write-Info "$($script:ToolName) $($script:ToolVersion)"
    Write-Info ''
    Write-Info 'environment'
    Write-Note "Windows build: $([Environment]::OSVersion.Version.Build)"
    Write-Note "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Note "home: $($script:State.Home)"
    Write-Note "app data root: $($script:State.DataRoot)"
    $app = Get-AppInfo
    if ($app.Kind -eq 'msix') {
        Write-Note 'install kind: MSIX (app data is virtualized under Packages\...\LocalCache)'
    }
    if ($app.Path) { Write-Note "Claude Desktop: $($app.Path) version $($app.Version)" }
    else { Write-Note 'Claude Desktop: not installed' }

    Write-Info ''
    Write-Info 'Claude Code settings'
    if (Test-Path -LiteralPath $script:State.Settings) {
        Write-Note "path: $($script:State.Settings)"
        $doc = $null
        $ok = $true
        try { $doc = Read-JsonFile $script:State.Settings } catch { $ok = $false }
        foreach ($k in @('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY',
                         'ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL',
                         'ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL',
                         'ANTHROPIC_DEFAULT_FABLE_MODEL')) {
            $v = ''
            if ($doc) { $v = [string](Get-SettingsValue $doc "env.$k") }
            if ($v) {
                if ($k -match 'TOKEN|API_KEY') { Write-Note "env.${k}: set ($(Get-ByteLength $v) bytes)" }
                else { Write-Note "env.${k}: set" }
            } else {
                Write-Note "env.${k}: unset"
            }
        }
        $m = ''
        if ($doc) { $m = [string](Get-SettingsValue $doc 'model') }
        if ($m) { Write-Note 'model: set' } else { Write-Note 'model: unset' }
        if ($ok) { Write-Note 'parses: yes' } else { Write-Note 'parses: NO' }
    } else {
        Write-Note "path: $($script:State.Settings) (absent)"
    }

    Write-Info ''
    Write-Info 'credential helper'
    if (Test-Path -LiteralPath $script:State.HelperCmd) {
        Write-Note "path: $($script:State.HelperCmd)"
        $run = Invoke-Helper
        Write-Note "exit: $($run.Code), credential bytes: $($run.Length)"
    } else {
        Write-Note 'not installed'
    }

    Write-Info ''
    Write-Info 'installed state'
    if (Test-Path -LiteralPath $script:State.StateFile) {
        Write-Note "state: $($script:State.StateFile)"
        Write-Note "configId: $(Get-StateValue 'configId')"
        Write-Note "configName: $(Get-StateValue 'configName')"
        Write-Note "baseUrl: $(Get-StateValue 'baseUrl')"
        Write-Note "authScheme: $(Get-StateValue 'authScheme')"
        Write-Note "tokenLength: $(Get-StateValue 'tokenLength')"
    } else {
        Write-Note 'state: not installed'
    }

    Write-Info ''
    Write-Info 'configuration library'
    if (Test-Path -LiteralPath $script:State.Library) {
        Write-Note "path: $($script:State.Library)"
        $metaPath = Join-Path $script:State.Library '_meta.json'
        if (Test-Path -LiteralPath $metaPath) {
            $applied = ''
            try { $applied = [string](Get-Prop (Read-JsonFile $metaPath) 'appliedId') } catch { }
            if ($applied) { Write-Note "appliedId: $applied" } else { Write-Note 'appliedId: <empty>' }
        }
    } else {
        Write-Note "path: $($script:State.Library) (absent)"
    }

    Write-Info ''
    Write-Info 'managed configuration'
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Claude') { Write-Note 'machine policy: PRESENT (it wins over this tool)' }
    else { Write-Note 'machine policy: absent' }
    if (Test-Path 'HKCU:\SOFTWARE\Policies\Claude') { Write-Note 'user policy: PRESENT' }
    else { Write-Note 'user policy: absent' }

    Write-Info ''
    Write-Info 'backups'
    $list = Get-BackupList
    if ($list.Count -eq 0) { Write-Note 'none' } else { foreach ($b in $list) { Write-Note $b } }

    Write-Info ''
    Write-Info 'application log (errors only, last 20 matches)'
    $log = $script:State.AppLog
    if ($log -and (Test-Path -LiteralPath $log)) {
        Write-Note "path: $log"
        Get-Content -LiteralPath $log -Tail 400 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'managed|configLibrary|schema|invalid|error' } |
            Select-Object -Last 20 | ForEach-Object { Write-Note "  $(ConvertTo-Redacted $_)" }
    } else {
        Write-Note 'no log found'
    }
}
