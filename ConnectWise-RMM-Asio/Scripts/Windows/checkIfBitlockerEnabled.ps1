#Requires -Version 5.1
<#
.SYNOPSIS
  Return 1 if any **non‑removable** (fixed) drives have BitLocker enabled; otherwise 0.
.DESCRIPTION
  Built for CW RMM (ConnectWise RMM - Asio) to run on a schedule (e.g., weekly) and feed a
  Yes/No custom field. The script inspects **fixed/local** drives only (excludes removable
  USB flash drives, optical, network, RAM disks) and checks BitLocker status per volume.

  Output is a **single line**: `1` if any fixed drive has BitLocker protection **On**,
  else `0`. Use this in CW RMM automation to set a boolean/flag custom field.

  Implementation details:
  - Prefers `Get-BitLockerVolume` when available.
  - Falls back to `manage-bde -status` for older hosts.
  - Runs fine as SYSTEM (no local files created). In mixed scenarios, it can self‑elevate
    when not already elevated unless `-NoElevate` is supplied.

.PARAMETER NoElevate
  Skip self‑elevation if not already elevated.

.OUTPUTS
  System.String — "1" or "0" on STDOUT for easy parsing by CW RMM.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\checkIfBitlockerEnabled.ps1
  # 1  (means at least one fixed drive has BitLocker enabled)
#>

param(
  [switch]$NoElevate
)

function Test-IsElevated {
  try { return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
  catch { return $false }
}

# Elevate when needed (CW RMM as SYSTEM is already elevated)
if (-not $NoElevate -and -not (Test-IsElevated)) {
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit 0
  } catch {
    Write-Warning "Elevation failed or was canceled; continuing without elevation."
  }
}

function Get-FixedDriveLetters {
  # Try modern Get-Volume first
  $letters = @()
  try {
    $letters = Get-Volume -ErrorAction Stop |
      Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
      Select-Object -ExpandProperty DriveLetter
  } catch {
    # Fall back to CIM for older builds
    try {
      $letters = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object { $_.DeviceID -match ':' } |
        ForEach-Object { $_.DeviceID.Substring(0,1) }
    } catch {}
  }
  return @($letters | Sort-Object -Unique)
}

function Get-BitLockerEnabledMap {
  param([string[]]$DriveLetters)
  $map = @{}

  $blCmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
  if ($blCmd) {
    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    foreach ($dl in $DriveLetters) {
      $present = Test-Path ("${dl}:\")
      $enabled = $false
      if ($present) {
        $v = $vols | Where-Object { $_.MountPoint -eq "${dl}:\\" }
        if ($null -ne $v) {
          $enabled = ($v.ProtectionStatus.ToString() -eq 'On')
        } else {
          $enabled = (Get-ManageBdeEnabled -Drive $dl)
        }
      }
      $map[$dl] = $enabled
    }
  } else {
    foreach ($dl in $DriveLetters) {
      $map[$dl] = (Get-ManageBdeEnabled -Drive $dl)
    }
  }
  return $map
}

function Get-ManageBdeEnabled {
  param([Parameter(Mandatory)] [ValidatePattern('^[A-Fa-f]$')] [string]$Drive)
  $present = Test-Path ("${Drive}:\")
  if (-not $present) { return $false }
  try {
    $raw = & manage-bde -status "${Drive}:\\" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $false }
    $prot = ($raw | Select-String -Pattern 'Protection Status:\s*(.*)' -AllMatches | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Select-Object -First 1)
    return ($prot -match 'On')
  } catch { return $false }
}

# --- main ---
$fixedLetters = Get-FixedDriveLetters
$bitlockerMap = Get-BitLockerEnabledMap -DriveLetters $fixedLetters
$anyEnabledFixed = $null -ne ($bitlockerMap.Values | Where-Object { $_ }) -and (($bitlockerMap.Values | Where-Object { $_ }).Count -gt 0)

# Emit single-line boolean for CW RMM custom field mapping
if ($anyEnabledFixed) { Write-Output '1' } else { Write-Output '0' }

exit 0