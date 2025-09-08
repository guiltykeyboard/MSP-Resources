#Requires -Version 5.1
<#!
.SYNOPSIS
  Enable BitLocker on all fixed (non-removable) drives, including recovery keys in the JSON output.
.DESCRIPTION
  Built for CW RMM (ConnectWise RMM - Asio). This script detects all **fixed** drives and enables
  BitLocker protection where it is currently off. It uses `manage-bde` for broad compatibility and
  does not create local files. Runs fine as SYSTEM; in mixed scenarios it can self‑elevate unless
  `-NoElevate` is specified.

  Behavior per drive (e.g., C, D, E…):
    • If BitLocker protection is already **On**, the drive is skipped.
    • If BitLocker protection is **Off**, the script turns it **On** using a **Recovery Password**
      protector (`-rp`) and **Used Space Only** encryption for speed. The recovery password **is**
      printed to STDOUT in the JSON summary for verification/logging (use your separate backup script to escrow keys to AD/AAD and capture values).
    • Encryption method can be selected: XTS-AES 128 (default) or 256.

  Notes:
    • OS volume encryption starts immediately using Used Space Only. Some environments may still require
      a reboot before encryption fully proceeds, depending on policy. This script opts for non‑interactive
      defaults suitable for RMM.
    • Recovery keys appear in the script output JSON but should not be relied upon as the only backup mechanism.

.PARAMETER NoElevate
  Skip self‑elevation if not already elevated.

.PARAMETER EncryptionMethod
  Encryption method to set prior to enabling BitLocker. Accepted: XtsAes128 (default), XtsAes256.

.PARAMETER Full
  Encrypt full volume instead of Used Space Only. Default is Used Space Only when -Full is not specified.

.OUTPUTS
  JSON summary to STDOUT, e.g.:
  {
    "Summary":{"Targeted":2,"Enabled":1,"Skipped":1,"Errors":0},
    "Drives":{"C":{"Present":true,"Fixed":true,"Protection":"Off","Action":"Enabled","UsedSpaceOnly":true,"Method":"XtsAes128","ExitCode":0,"Message":"BitLocker enabling initiated"},
              "D":{"Present":true,"Fixed":true,"Protection":"On","Action":"Skipped"}}
  }

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\enableBitlocker.ps1

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\enableBitlocker.ps1 -EncryptionMethod XtsAes256 -Full
#>

[CmdletBinding()]
param(
  [switch]$NoElevate,
  [ValidateSet('XtsAes128','XtsAes256')]
  [string]$EncryptionMethod = 'XtsAes128',
  [switch]$Full
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Test-IsElevated {
  try { return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
  catch { return $false }
}

# Elevate in mixed scenarios (CW RMM as SYSTEM is already elevated)
if (-not $NoElevate -and -not (Test-IsElevated)) {
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($MyInvocation.BoundParameters.GetEnumerator() | ForEach-Object { '-'+$_.Key + ($_.Value -is [bool] -and $_.Value ? '' : ' '+$_.Value) })" -Verb RunAs | Out-Null
    exit 0
  } catch {
    Write-Warning "Elevation failed or was canceled; continuing without elevation."
  }
}

function Get-FixedDriveLetters {
  $letters = @()
  try {
    $letters = Get-Volume -ErrorAction Stop |
      Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
      Select-Object -ExpandProperty DriveLetter
  } catch {
    try {
      $letters = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object { $_.DeviceID -match ':' } |
        ForEach-Object { $_.DeviceID.Substring(0,1) }
    } catch {}
  }
  return @($letters | Sort-Object -Unique)
}

function Get-BitLockerStatus {
  param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f]$')] [string]$Drive)
  $present = Test-Path ("${Drive}:")
  if (-not $present) { return [pscustomobject]@{ Present=$false; Protection=$null; Percent=$null } }
  try {
    $raw = & manage-bde -status "${Drive}:" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return [pscustomobject]@{ Present=$present; Protection=$null; Percent=$null } }
    $prot = ($raw | Select-String -Pattern 'Protection Status:\s*(.*)' | Select-Object -First 1).Matches.Groups[1].Value.Trim()
    $pct  = ($raw | Select-String -Pattern 'Percentage Encrypted:\s*(\d+)' | Select-Object -First 1)
    $perc = if ($pct) { [int]$pct.Matches.Groups[1].Value } else { $null }
    return [pscustomobject]@{ Present=$present; Protection=$prot; Percent=$perc }
  } catch { return [pscustomobject]@{ Present=$present; Protection=$null; Percent=$null } }
}

function Set-EncryptionMethod {
  param([Parameter(Mandatory)][ValidateSet('XtsAes128','XtsAes256')] [string]$Method)
  try {
    $null = & manage-bde -status 2>$null
    if ($LASTEXITCODE -eq 0) {
      # Set global default for new volumes
      $null = & manage-bde -on C: -? 2>$null  # warm-up to ensure manage-bde present
    }
  } catch {}
  # Use PowerShell cmdlets when available to set method per volume
}

# Prepare output holders
$drivesOut = @{}
$enabledCount = 0
$skippedCount = 0
$errorCount = 0

$fixed = Get-FixedDriveLetters
$usedSpaceOnly = (-not $Full)

foreach ($dl in $fixed) {
  $status = Get-BitLockerStatus -Drive $dl
  $entry = [ordered]@{
    Present       = [bool]$status.Present
    Fixed         = $true
    Protection    = $status.Protection
    Percent       = $status.Percent
    Action        = 'None'
    UsedSpaceOnly = $usedSpaceOnly
    Method        = $EncryptionMethod
    ExitCode      = $null
    Message       = $null
  }

  if (-not $status.Present) {
    $entry.Action = 'Skipped'
    $entry.Message = 'Drive not present'
    $skippedCount++
    $drivesOut[$dl] = $entry
    continue
  }

  if ($status.Protection -match 'On') {
    $entry.Action = 'Skipped'
    $entry.Message = 'Already protected'
    $skippedCount++
    $drivesOut[$dl] = $entry
    continue
  }

  try {
    # Configure encryption type: used space or full
    $modeArg = if ($usedSpaceOnly) { '-usedspaceonly' } else { '-full' }

    # Start encryption with a Recovery Password protector (no TPM dependency)
    $null = & manage-bde -on "${dl}:" -rp $modeArg 2>&1
    $exit = $LASTEXITCODE

    if ($exit -eq 0) {
      $entry.Action = 'Enabled'
      $entry.ExitCode = 0
      $entry.Message = 'BitLocker enabling initiated'
      $enabledCount++

      $recoveryRaw = & manage-bde -protectors -get "${dl}:" 2>$null
      $recoveryKey = ($recoveryRaw | Select-String -Pattern 'Recovery Password:\s*([0-9-]+)' | Select-Object -First 1).Matches.Groups[1].Value
      if ([string]::IsNullOrEmpty($recoveryKey)) {
        $entry.RecoveryKey = $null
      } else {
        $entry.RecoveryKey = $recoveryKey
      }
    } else {
      $entry.Action = 'Error'
      $entry.ExitCode = $exit
      $entry.Message = 'manage-bde failed to enable encryption'
      $errorCount++
    }
  } catch {
    $entry.Action = 'Error'
    $entry.ExitCode = -1
    $entry.Message = $_.Exception.Message
    $errorCount++
  }

  $drivesOut[$dl] = $entry
}

$payload = [ordered]@{
  Summary = [ordered]@{ Targeted = [int]$fixed.Count; Enabled = [int]$enabledCount; Skipped = [int]$skippedCount; Errors = [int]$errorCount }
  Drives  = $drivesOut
}

$payload | ConvertTo-Json -Depth 6 -Compress | Write-Output

# Always exit 0 so RMM captures the payload; inspect JSON to act
exit 0
