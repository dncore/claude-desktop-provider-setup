# Config-library manager, Windows.
# Reads and writes %LOCALAPPDATA%\Claude-3p\configLibrary\
# Implements src/common/SPEC.md section 7.

# Path is NOT stored here: $script:State.Library is finalised by
# Initialize-ClaudePaths, which runs after this file is dot-sourced. Deriving
# the path on every use keeps it correct for an MSIX install, whose library
# lives under the package's virtualized %LOCALAPPDATA%.
$script:Meta = @{
    AppliedId  = ''
    Entries    = New-Object System.Collections.ArrayList
    Existed    = $false
}

function Get-MetaPath { return (Join-Path $script:State.Library '_meta.json') }

function Get-MetaState { return $script:Meta }

function Load-Meta {
    $script:Meta.Entries = New-Object System.Collections.ArrayList
    $script:Meta.AppliedId = ''
    $script:Meta.Existed = $false

    if (Test-Path -LiteralPath (Get-MetaPath)) {
        try {
            $doc = Read-JsonFile (Get-MetaPath)
            $script:Meta.Existed = $true
            $applied = Get-Prop $doc 'appliedId'
            if ($null -ne $applied) { $script:Meta.AppliedId = [string]$applied }
            $entries = Get-Prop $doc 'entries'
            if ($null -ne $entries) {
                foreach ($e in @($entries)) {
                    $rec = [ordered]@{}
                    foreach ($p in $e.PSObject.Properties) { $rec[$p.Name] = $p.Value }
                    [void]$script:Meta.Entries.Add($rec)
                }
            }
        } catch {
            # An unparseable _meta.json is treated as absent; the backup taken
            # before any mutation preserves the original bytes.
            Add-Warning 'meta-unreadable' "$(Get-MetaPath) could not be parsed"
            $script:Meta.Entries = New-Object System.Collections.ArrayList
            $script:Meta.AppliedId = ''
        }
    }
}

function Find-EntryIndex {
    param([string]$Id)
    for ($i = 0; $i -lt $script:Meta.Entries.Count; $i++) {
        if ([string]$script:Meta.Entries[$i]['id'] -ceq $Id) { return $i }
    }
    return -1
}

function Assert-MetaInvariant {
    if ($script:Meta.AppliedId -eq '') { return }
    if (-not (Test-ConfigId $script:Meta.AppliedId)) {
        Stop-WithError 6 'meta-invariant' "appliedId '$($script:Meta.AppliedId)' is not a valid configuration id"
    }
    if ((Find-EntryIndex $script:Meta.AppliedId) -lt 0) {
        Stop-WithError 6 'meta-invariant' "appliedId '$($script:Meta.AppliedId)' names no existing entry; refusing to write"
    }
}

function Save-Meta {
    Assert-MetaInvariant
    $doc = [ordered]@{
        appliedId = $script:Meta.AppliedId
        entries   = @($script:Meta.Entries)
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 12
    $tmp = "$(Get-MetaPath).tmp"
    Write-TextNoBom $tmp ($json + "`n")
    Move-Item -LiteralPath $tmp -Destination (Get-MetaPath) -Force
}

function Write-ConfigFile {
    param([string]$Id, [string]$Json)
    $target = Join-Path $script:State.Library "$Id.json"
    $tmp = Join-Path $script:State.Library ".$Id.json.tmp"
    Write-TextNoBom $tmp ($Json + "`n")

    # Parse what we are about to install: a malformed file would make Claude
    # Desktop reject the whole configuration.
    try {
        [void](Read-JsonFile $tmp)
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Stop-WithError 6 'invalid-output' 'generated configuration is not valid JSON'
    }
    Move-Item -LiteralPath $tmp -Destination $target -Force
}

function Assert-Library {
    if (Test-Path -LiteralPath $script:State.Library) { return }

    if (-not (Test-Path -LiteralPath $script:State.AppData)) {
        # On macOS the app creates Claude-3p on first launch, so its absence is
        # a real error. On Windows the current MSIX build does not: third-party
        # mode has never run, and it cannot run until a configuration exists.
        # That is a chicken and egg, so the tool creates the tree itself.
        # Observed on Windows 10 with Claude 6.28899.6.0: after a full launch
        # at the login screen, only ...\LocalCache\Local\Claude existed.
        Add-Warning 'library-created' $script:State.Library
    }
    New-Item -ItemType Directory -Path $script:State.Library -Force | Out-Null
}

function Install-Config {
    param([string]$Json, [string]$Name, [string]$ExistingId)

    Load-Meta

    if ($ExistingId) {
        $id = $ExistingId
        if ((Find-EntryIndex $id) -lt 0) {
            Stop-WithError 6 'state-stale' @"
The recorded configuration id $id is no longer present in the Claude Desktop
library. Run --uninstall to clear the stale record, then install again.
"@
        }
    } else {
        $id = New-ConfigId
        if (-not (Test-ConfigId $id)) {
            Stop-WithError 6 'io-error' 'could not generate a valid configuration id'
        }
        [void]$script:Meta.Entries.Add([ordered]@{ id = $id; name = $Name })
    }

    $previous = $script:Meta.AppliedId
    Write-ConfigFile $id $Json
    $script:Meta.AppliedId = $id
    Save-Meta

    return @{
        Id          = $id
        Previous    = $previous
        MetaExisted = $script:Meta.Existed
    }
}

function Remove-Config {
    param([string]$Id, [string]$RestoreTo = '')

    Load-Meta
    $idx = Find-EntryIndex $Id
    if ($idx -lt 0) {
        Add-Warning 'not-installed' "configuration id $Id is already absent"
        return @{ Changed = $false }
    }

    $script:Meta.Entries.RemoveAt($idx)

    if ($script:Meta.AppliedId -ceq $Id) {
        $next = ''
        if ($RestoreTo -ne '' -and (Find-EntryIndex $RestoreTo) -ge 0) {
            $next = $RestoreTo
        } elseif ($script:Meta.Entries.Count -gt 0) {
            $next = [string]$script:Meta.Entries[0]['id']
        }
        $script:Meta.AppliedId = $next
    }

    $file = Join-Path $script:State.Library "$Id.json"
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    Save-Meta
    return @{ Changed = $true }
}
