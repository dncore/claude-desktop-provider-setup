# Backup, restore and state management, Windows.
# Implements src/common/SPEC.md section 9.

$script:LastBackup = ''

function Initialize-StateDir {
    if (-not (Test-Path -LiteralPath $script:State.StateDir)) {
        New-Item -ItemType Directory -Path $script:State.StateDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:State.HelperDir)) {
        New-Item -ItemType Directory -Path $script:State.HelperDir -Force | Out-Null
    }
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-Backup {
    param([string]$Label = 'manual')

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $target = Join-Path $script:State.BackupRoot $stamp
    if (Test-Path -LiteralPath $target) { $target = "$target-$PID" }
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    $files = @()
    $candidates = @()
    $metaPath = Join-Path $script:State.Library '_meta.json'
    if (Test-Path -LiteralPath $metaPath) { $candidates += $metaPath }
    if (Test-Path -LiteralPath $script:State.Library) {
        $candidates += (Get-ChildItem -LiteralPath $script:State.Library -Filter '*.json' -File |
                       Where-Object { $_.Name -eq '_meta.json' -or (Test-ConfigId ($_.BaseName)) } |
                       ForEach-Object { $_.FullName })
    }

    foreach ($f in ($candidates | Select-Object -Unique)) {
        $name = Split-Path $f -Leaf
        $dest = Join-Path $target $name
        Copy-Item -LiteralPath $f -Destination $dest -Force
        $files += [ordered]@{
            name   = $name
            bytes  = (Get-Item -LiteralPath $f).Length
            sha256 = (Get-FileSha256 $f)
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        createdAt     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        label         = $Label
        libraryPath   = $script:State.Library
        files         = @($files)
    }
    Write-TextNoBom (Join-Path $target 'manifest.json') ((ConvertTo-Json -InputObject $manifest -Depth 10) + "`n")

    $script:LastBackup = $target
    return $target
}

function Test-BackupIntegrity {
    param([string]$Path)
    $manifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Stop-WithError 5 'backup-missing' "no manifest in $Path"
    }
    $doc = $null
    try { $doc = Read-JsonFile $manifestPath } catch {
        Stop-WithError 5 'backup-invalid' "manifest in $Path is malformed"
    }
    $files = Get-Prop $doc 'files'
    if ($null -eq $files) { Stop-WithError 5 'backup-invalid' "manifest in $Path is malformed" }

    foreach ($entry in @($files)) {
        $name = [string](Get-Prop $entry 'name')
        $want = [string](Get-Prop $entry 'sha256')
        if (-not $name) { Stop-WithError 5 'backup-invalid' 'a manifest entry has no name' }
        $file = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $file)) {
            Stop-WithError 5 'backup-invalid' "backup is missing $name"
        }
        if ((Get-FileSha256 $file) -cne $want) {
            Stop-WithError 5 'backup-corrupt' "$name does not match its recorded digest"
        }
    }
    return $true
}

function Restore-Backup {
    param([string]$Path)

    if ($Path -notmatch '[\\/]' -and (Test-Path -LiteralPath (Join-Path $script:State.BackupRoot $Path))) {
        $Path = Join-Path $script:State.BackupRoot $Path
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Stop-WithError 5 'backup-missing' "backup directory not found: $Path"
    }
    if (-not (Test-Path -LiteralPath $script:State.Library)) {
        New-Item -ItemType Directory -Path $script:State.Library -Force | Out-Null
    }

    Test-BackupIntegrity $Path | Out-Null

    foreach ($f in (Get-ChildItem -LiteralPath $Path -Filter '*.json' -File)) {
        if ($f.Name -eq 'manifest.json') { continue }
        if ($f.Name -ne '_meta.json' -and -not (Test-ConfigId $f.BaseName)) {
            Add-Warning 'backup-skipped' "$($f.Name) is not a configuration file"
            continue
        }
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $script:State.Library $f.Name) -Force
    }
    return $Path
}

function Get-BackupList {
    if (-not (Test-Path -LiteralPath $script:State.BackupRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:State.BackupRoot -Directory |
             Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-LatestBackup {
    $list = Get-BackupList
    if ($list.Count -eq 0) { return '' }
    return (Join-Path $script:State.BackupRoot $list[-1])
}

function Write-State {
    param(
        [string]$ConfigId,
        [string]$ConfigName,
        [string]$PreviousAppliedId,
        [bool]$MetaExisted,
        [string[]]$HelperFiles
    )
    Initialize-StateDir
    $ids = @()
    foreach ($m in $script:Core.Models) { $ids += $m.name }

    $doc = [ordered]@{
        schemaVersion      = 1
        toolVersion        = $script:ToolVersion
        platform           = 'windows'
        installedAt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        configId           = $ConfigId
        configName         = $ConfigName
        previousAppliedId  = $PreviousAppliedId
        metaExistedBefore  = $MetaExisted
        helperFiles        = @($HelperFiles)
        baseUrl            = $script:Core.BaseUrl
        authScheme         = $script:Core.AuthScheme
        tokenSource        = $script:Core.TokenSource
        tokenLength        = (Get-ByteLength $script:Core.Token)
        modelIds           = @($ids)
    }
    $tmp = "$($script:State.StateFile).tmp"
    Write-TextNoBom $tmp ((ConvertTo-Json -InputObject $doc -Depth 10) + "`n")
    Move-Item -LiteralPath $tmp -Destination $script:State.StateFile -Force
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:State.StateFile)) { return $null }
    try { return (Read-JsonFile $script:State.StateFile) } catch { return $null }
}

function Assert-State {
    if (-not (Test-Path -LiteralPath $script:State.StateFile)) {
        Stop-WithError 5 'not-installed' @"
$($script:State.StateFile) does not exist. Nothing is recorded as installed by
this tool.
"@
    }
}

function Get-StateValue {
    param([string]$Name)
    $doc = Read-State
    if ($null -eq $doc) { return '' }
    $v = Get-Prop $doc $Name
    if ($null -eq $v) { return '' }
    return [string]$v
}

function Get-StateArray {
    param([string]$Name)
    $doc = Read-State
    if ($null -eq $doc) { return @() }
    $v = Get-Prop $doc $Name
    if ($null -eq $v) { return @() }
    return @($v)
}
