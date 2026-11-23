# Conformance runner, Windows.
#
# Runs every fixture in tests\fixtures\common through Cli.ps1 plan in a
# throwaway USERPROFILE with a scrubbed environment, then compares the plan
# with the fixture's expect.json field by field.
#
# This must reach the same verdict as tests/run-conformance.sh on the same
# fixtures. Divergence is a bug in one of the two implementations.

param(
    [string]$Filter = ''
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$Fixtures = Join-Path $Root 'tests\fixtures\common'
$Cli      = Join-Path $Root 'src\windows\Cli.ps1'

$Vars = @(
    'ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_DEFAULT_FABLE_MODEL'
)

$ModelsFields = @('name','labelOverride','supports1m','prefer1m','anthropicFamilyTier',
                  'isFamilyDefault','behavesAs','maxEffort')

$Script:Pass = 0
$Script:Fail = 0
$Script:Failed = New-Object System.Collections.ArrayList
$Script:Case = ''

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    foreach ($p in $Object.PSObject.Properties) {
        if ($p.Name -ceq $Name) { return $p.Value }
    }
    return $null
}

function As-Text {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [array]) { return (($Value | ForEach-Object { As-Text $_ }) -join ',') }
    return [string]$Value
}

function Add-Failure {
    param([string]$Message)
    $Script:Fail++
    [void]$Script:Failed.Add("  - $($Script:Case): $Message")
    Write-Host "FAIL $($Script:Case): $Message"
}

function Compare-Field {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { return $true }
    Add-Failure "$Label expected [$Expected] got [$Actual]"
    return $false
}

function Compare-Case {
    param([string]$CasePath, [string]$OutText, [int]$Code, [string]$FakeHome, [string]$ErrFile)

    $expPath = Join-Path $CasePath 'expect.json'
    $exp = [System.IO.File]::ReadAllText($expPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    try {
        $act = $OutText | ConvertFrom-Json
    } catch {
        $snippet = ''
        if ($OutText) { $snippet = $OutText.Substring(0, [Math]::Min(200, $OutText.Length)) }
        Add-Failure "plan output is not valid JSON (exit $Code): $snippet"
        return
    }

    $wantOk = As-Text (Get-Prop $exp 'ok')

    if ($wantOk -eq 'true') {
        [void](Compare-Field 'exit code' '0' "$Code")
        foreach ($f in @('baseUrl','baseUrlHost','authScheme','tokenSource','tokenLength',
                         'credentialKind','deploymentMode','helperTtlSec','modelDiscoveryEnabled')) {
            [void](Compare-Field $f (As-Text (Get-Prop $exp $f)) (As-Text (Get-Prop $act $f)))
        }

        $expModels = @(Get-Prop $exp 'models')
        $actModels = @(Get-Prop $act 'models')
        if (Compare-Field 'models count' "$($expModels.Count)" "$($actModels.Count)") {
            for ($i = 0; $i -lt $expModels.Count; $i++) {
                foreach ($f in $ModelsFields) {
                    [void](Compare-Field "models[$i].$f" `
                        (As-Text (Get-Prop $expModels[$i] $f)) `
                        (As-Text (Get-Prop $actModels[$i] $f)))
                }
            }
        }

        $expWarn = @(Get-Prop $exp 'warnings')
        $actWarn = @(Get-Prop $act 'warnings')
        if (Compare-Field 'warnings count' "$($expWarn.Count)" "$($actWarn.Count)") {
            for ($i = 0; $i -lt $expWarn.Count; $i++) {
                [void](Compare-Field "warnings[$i].kind" `
                    (As-Text (Get-Prop $expWarn[$i] 'kind')) `
                    (As-Text (Get-Prop $actWarn[$i] 'kind')))
            }
        }
        [void](Compare-Field 'errors count' '0' "$(@(Get-Prop $act 'errors').Count)")
    } else {
        $expErr = @(Get-Prop $exp 'errors')
        $actErr = @(Get-Prop $act 'errors')
        [void](Compare-Field 'error kind' (As-Text (Get-Prop $expErr[0] 'kind')) (As-Text (Get-Prop $actErr[0] 'kind')))
        [void](Compare-Field 'exit code' (As-Text (Get-Prop $expErr[0] 'code')) "$Code")
        [void](Compare-Field 'ok flag' 'false' (As-Text (Get-Prop $act 'ok')))
        [void](Compare-Field 'errors count' '1' "$($actErr.Count)")
    }

    # Redaction: the fixture's credential must not appear in either stream.
    $settingsPath = Join-Path $FakeHome '.claude\settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $doc = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $envNode = Get-Prop $doc 'env'
            $token = As-Text (Get-Prop $envNode 'ANTHROPIC_AUTH_TOKEN')
            if (-not $token) { $token = As-Text (Get-Prop $envNode 'ANTHROPIC_API_KEY') }
            if ($token) {
                if ($OutText.Contains($token)) { Add-Failure 'credential leaked on stdout' }
                if (Test-Path -LiteralPath $ErrFile) {
                    $errText = [System.IO.File]::ReadAllText($ErrFile, [System.Text.Encoding]::UTF8)
                    if ($errText.Contains($token)) { Add-Failure 'credential leaked on stderr' }
                }
            }
        } catch { }
    }
}

function Invoke-Case {
    param([System.IO.DirectoryInfo]$CaseDir)

    $Script:Case = $CaseDir.Name
    if ($Filter -and ($CaseDir.Name -notlike "*$Filter*")) { return }

    $before = $Script:Fail

    $fakeHome = Join-Path ([System.IO.Path]::GetTempPath()) ("cds-conf-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') -Force | Out-Null

    $settingsSrc = Join-Path $CaseDir.FullName 'settings.json'
    if (Test-Path -LiteralPath $settingsSrc) {
        Copy-Item -LiteralPath $settingsSrc -Destination (Join-Path $fakeHome '.claude\settings.json')
    }

    $saved = @{}
    foreach ($v in $Vars) { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
    $savedDataRoot = $env:CDS_DATA_ROOT
    $savedAppPath  = $env:CDS_APP_PATH

    try {
        foreach ($v in $Vars) { [Environment]::SetEnvironmentVariable($v, '') }
        # Plan mode writes nothing, but path resolution must not touch the
        # machine's real Claude Desktop data.
        $env:CDS_DATA_ROOT = Join-Path $fakeHome 'Local'
        $env:CDS_APP_PATH  = Join-Path $fakeHome 'Local\AnthropicClaude\claude.exe'

        $envSrc = Join-Path $CaseDir.FullName 'env.json'
        if (Test-Path -LiteralPath $envSrc) {
            $envDoc = [System.IO.File]::ReadAllText($envSrc, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($v in $Vars) {
                $val = Get-Prop $envDoc $v
                if ($null -ne $val) { [Environment]::SetEnvironmentVariable($v, [string]$val) }
            }
        }

        $runArgs = @('plan')
        $argsSrc = Join-Path $CaseDir.FullName 'args.json'
        if (Test-Path -LiteralPath $argsSrc) {
            $list = [System.IO.File]::ReadAllText($argsSrc, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($a in @($list)) { $runArgs += [string]$a }
        }
        $mappingSrc = Join-Path $CaseDir.FullName 'mapping.json'
        if (Test-Path -LiteralPath $mappingSrc) { $runArgs += @('--mapping', $mappingSrc) }

        $previousProfile = $env:USERPROFILE
        $env:USERPROFILE = $fakeHome
        $errFile = Join-Path $fakeHome 'stderr.txt'
        $outFile = Join-Path $fakeHome 'stdout.txt'
        $outText = ''
        try {
            # Start-Process is used rather than the call operator because
            # Windows PowerShell turns a native command's stderr into a
            # terminating error record under $ErrorActionPreference = 'Stop',
            # which would abort the run on the first expected failure.
            $argList = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Cli) + $runArgs
            $quoted = @()
            foreach ($a in $argList) {
                if ($a -match '\s') { $quoted += ('"' + $a + '"') } else { $quoted += $a }
            }
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $quoted `
                        -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $code = $proc.ExitCode
            if (Test-Path -LiteralPath $outFile) {
                $outText = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8).Trim()
            }
        } finally {
            $env:USERPROFILE = $previousProfile
        }

        Compare-Case $CaseDir.FullName $outText $code $fakeHome $errFile
    } finally {
        foreach ($v in $Vars) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
        $env:CDS_DATA_ROOT = $savedDataRoot
        $env:CDS_APP_PATH  = $savedAppPath
        Remove-Item -LiteralPath $fakeHome -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($Script:Fail -eq $before) { $Script:Pass++ }
}

if (-not (Test-Path -LiteralPath $Fixtures)) {
    Write-Host "missing fixtures directory: $Fixtures"
    exit 2
}

foreach ($d in (Get-ChildItem -LiteralPath $Fixtures -Directory | Sort-Object Name)) {
    Invoke-Case $d
}

Write-Host ''
Write-Host "$($Script:Pass) passed, $($Script:Fail) failed"
if ($Script:Fail -ne 0) {
    Write-Host 'failed cases:'
    foreach ($l in $Script:Failed) { Write-Host $l }
    exit 1
}
exit 0
