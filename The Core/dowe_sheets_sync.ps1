# =============================================================================
# DOWE Google Sheets -> 2DA Sync Tool (PowerShell Version)
# =============================================================================
# Version: 1.0  |  Requires: PowerShell 5.1+ (built into Windows 10/11)
# No external dependencies. Uses only built-in Windows networking.
#
# USAGE:
#   .\dowe_sheets_sync.ps1                  # Normal sync
#   .\dowe_sheets_sync.ps1 -DryRun          # Preview only
#   .\dowe_sheets_sync.ps1 -Force           # Re-sync even if unchanged
#   .\dowe_sheets_sync.ps1 -Watch           # Keep running every 5 minutes
#
# TASK SCHEDULER SETUP (Windows):
#   1. Open Task Scheduler
#   2. Create Basic Task -> "DOWE Sheets Sync"
#   3. Trigger: Daily, repeat every 5 minutes for 1 day
#   4. Action: Start a program
#      Program: powershell.exe
#      Arguments: -ExecutionPolicy Bypass -File "C:\DOWE\dowe_sheets_sync.ps1"
# =============================================================================

param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Watch,
    [int]$WatchInterval = 300
)

# =============================================================================
# CONFIGURATION - EDIT THIS SECTION
# =============================================================================

# Path to your NWN server override or development folder
$OutputDir = "C:\NeverwinterNights\NWN\override"

# State file: remembers what was last synced (prevents unnecessary writes)
$StateFile = "$PSScriptRoot\sync_state.json"

# Log file (set to $null to disable file logging)
$LogFile = "$PSScriptRoot\sync.log"

# =============================================================================
# SHEET MAP - Edit these URLs
# Get URL: Google Sheets -> File -> Share -> Publish to web -> CSV -> Copy link
# =============================================================================

$SheetMap = @{
    "core_package" = "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?gid=0&single=true&output=csv"
    "enc_dynamic"  = "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?gid=123456789&single=true&output=csv"
    "enc_hub"      = "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?gid=987654321&single=true&output=csv"
    "ai_hub"       = "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?gid=111222333&single=true&output=csv"
    "core_admin"   = "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?gid=444555666&single=true&output=csv"
}

# Minimum column widths (optional, cosmetic only)
$ForcedWidths = @{
    "core_package" = @{ "PACKAGE"=20; "SCRIPT"=20; "BOOT_SCRIPT"=20; "DEBUG_VAR"=18 }
    "ai_hub"       = @{ "SYSTEM"=16; "SCRIPT"=20; "DEBUG_VAR"=24 }
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Msg"
    Write-Host $line
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}

function Get-Checksum {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
    return [BitConverter]::ToString($hash).Replace("-","").ToLower()
}

function Load-State {
    if (Test-Path $StateFile) {
        try {
            return Get-Content $StateFile | ConvertFrom-Json -AsHashtable
        } catch { }
    }
    return @{}
}

function Save-State {
    param([hashtable]$State)
    $State | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function ConvertTo-2DA {
    param(
        [string]$CsvText,
        [string]$Name
    )

    # Parse CSV
    $reader = [System.IO.StringReader]::new($CsvText)
    $allRows = @()
    while ($null -ne ($line = $reader.ReadLine())) {
        $allRows += ,$line
    }

    $headerRow = $null
    $dataRows = @()

    foreach ($line in $allRows) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("//")) { continue }

        # Simple CSV parse (handles quoted fields)
        $parsed = @()
        $inQuote = $false
        $current = ""
        foreach ($ch in $trimmed.ToCharArray()) {
            if ($ch -eq '"') { $inQuote = -not $inQuote }
            elseif ($ch -eq ',' -and -not $inQuote) { $parsed += $current.Trim(); $current = "" }
            else { $current += $ch }
        }
        $parsed += $current.Trim()

        if ($null -eq $headerRow) {
            $headerRow = $parsed
        } else {
            $dataRows += ,$parsed
        }
    }

    if ($null -eq $headerRow -or $headerRow.Count -eq 0) {
        Write-Log "  WARNING [$Name]: No header row found."
        return ""
    }

    $numCols = $headerRow.Count
    $forced = if ($ForcedWidths.ContainsKey($Name)) { $ForcedWidths[$Name] } else { @{} }

    # Clean data rows: empty cells -> ****, spaces -> _
    $cleanRows = @()
    foreach ($row in $dataRows) {
        $cleaned = @()
        for ($ci = 0; $ci -lt $numCols; $ci++) {
            $cell = if ($ci -lt $row.Count) { $row[$ci] } else { "" }
            if ($cell -eq "") { $cell = "****" }
            elseif ($cell.Contains(" ")) { $cell = $cell.Replace(" ", "_") }
            $cleaned += $cell
        }
        $cleanRows += ,$cleaned
    }

    # Compute column widths
    $colWidths = @()
    for ($ci = 0; $ci -lt $numCols; $ci++) {
        $col = $headerRow[$ci]
        $maxW = $col.Length
        foreach ($row in $cleanRows) {
            if ($ci -lt $row.Count -and $row[$ci].Length -gt $maxW) { $maxW = $row[$ci].Length }
        }
        $minForced = if ($forced.ContainsKey($col)) { $forced[$col] } else { 0 }
        $colWidths += [Math]::Max($maxW + 2, $minForced + 2)
    }

    $idxWidth = [Math]::Max(($cleanRows.Count - 1).ToString().Length + 2, 6)

    # Build output
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("2DA V2.0")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("// Auto-generated by DOWE Sheets Sync  |  Source: $Name")
    [void]$sb.AppendLine("// Last sync: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("// DO NOT EDIT MANUALLY - edit the Google Sheet and re-sync")
    [void]$sb.AppendLine("")

    # Header
    $headerLine = " " * $idxWidth
    for ($ci = 0; $ci -lt $numCols; $ci++) {
        $headerLine += $headerRow[$ci].PadRight($colWidths[$ci])
    }
    [void]$sb.AppendLine($headerLine.TrimEnd())

    # Data rows
    for ($ri = 0; $ri -lt $cleanRows.Count; $ri++) {
        $rowLine = $ri.ToString().PadRight($idxWidth)
        for ($ci = 0; $ci -lt $numCols; $ci++) {
            $cell = if ($ci -lt $cleanRows[$ri].Count) { $cleanRows[$ri][$ci] } else { "****" }
            $rowLine += $cell.PadRight($colWidths[$ci])
        }
        [void]$sb.AppendLine($rowLine.TrimEnd())
    }

    return $sb.ToString()
}

function Sync-Sheet {
    param(
        [string]$Name,
        [string]$Url,
        [hashtable]$State
    )

    Write-Log "  Checking $Name.2da ..."

    if ($Url.Contains("YOUR_SHEET_ID")) {
        Write-Log "  SKIP [$Name]: URL not configured (still contains YOUR_SHEET_ID)"
        return $false
    }

    # Download
    try {
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec 30 -UseBasicParsing
        $csvText = $response.Content
    } catch {
        Write-Log "  ERROR [$Name]: Download failed - $($_.Exception.Message)"
        return $false
    }

    # Change detection
    $cs = Get-Checksum $csvText
    if (-not $Force -and $State.ContainsKey($Name) -and $State[$Name] -eq $cs) {
        Write-Log "  $Name.2da: unchanged (skipped)"
        return $false
    }

    # Convert
    $tdaText = ConvertTo-2DA -CsvText $csvText -Name $Name
    if ([string]::IsNullOrWhiteSpace($tdaText)) {
        Write-Log "  ERROR [$Name]: Conversion produced empty output."
        return $false
    }

    $outPath = Join-Path $OutputDir "$Name.2da"

    if ($DryRun) {
        Write-Log "  DRY RUN: Would write $outPath"
        $lines = $tdaText.Split("`n")
        $preview = $lines[0..([Math]::Min(9, $lines.Count-1))]
        foreach ($l in $preview) { Write-Log "  | $l" }
    } else {
        if (-not (Test-Path $OutputDir)) {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        }
        # Atomic write
        $tmpPath = "$outPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $tdaText, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmpPath -Destination $outPath -Force
        $lineCount = ($tdaText.Split("`n")).Count
        Write-Log "  UPDATED: $outPath  ($lineCount lines)"
    }

    $State[$Name] = $cs
    return $true
}

function Run-Sync {
    Write-Log ("=" * 60)
    Write-Log "DOWE Sheets Sync starting  (DryRun=$DryRun, Force=$Force)"
    Write-Log "Output directory: $OutputDir"
    Write-Log "Sheets to sync: $($SheetMap.Count)"

    $state = Load-State
    $updated = @()

    foreach ($entry in $SheetMap.GetEnumerator()) {
        $changed = Sync-Sheet -Name $entry.Key -Url $entry.Value -State $state
        if ($changed) { $updated += $entry.Key }
    }

    Save-State -State $state

    if ($updated.Count -gt 0) {
        Write-Log ""
        Write-Log "SYNC COMPLETE: $($updated.Count) file(s) updated: $($updated -join ', ')"
        Write-Log ""
        Write-Log "NEXT STEP: In-game, type:  /*reload `"your_password`""
        Write-Log "  This reloads all DOWE 2DA caches without server restart."
    } else {
        Write-Log "SYNC COMPLETE: No changes detected."
    }
    Write-Log ("=" * 60)

    return $updated
}

# =============================================================================
# ENTRY POINT
# =============================================================================

if ($Watch) {
    Write-Log "Watch mode: checking every $WatchInterval seconds. Ctrl+C to stop."
    while ($true) {
        Run-Sync
        Start-Sleep -Seconds $WatchInterval
    }
} else {
    Run-Sync
}
