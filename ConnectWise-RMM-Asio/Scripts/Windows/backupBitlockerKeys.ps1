#Requires -Version 5.1
<#!
.SYNOPSIS
  Inventory BitLocker recovery passwords for fixed drives and escrow them to AD/Azure AD when joined.
.DESCRIPTION
  Designed for CW RMM (ConnectWise RMM - Asio). Runs correctly as SYSTEM. No local files are created and
  the ONLY output is a compact JSON document to STDOUT, suitable for storing in a device-level custom field.

  Behavior:
    • Enumerates FIXED (non‑removable) volumes.
    • Collects Recovery Password protectors (48‑digit) per drive using manage-bde parsing for reliability.
    • If the device is domain‑joined, attempts on‑prem AD escrow via `manage-bde -protectors -adbackup`.
    • If the device is Azure AD/Entra ID joined and `BackupToAAD-BitLockerKeyProtector` is available,
      attempts AAD escrow for each protector.

  Mixed scenarios: the script can self‑elevate when not already elevated unless -NoElevate is provided.

.PARAMETER NoElevate
  Skip self‑elevation if not already elevated (useful for interactive testing). RMM as SYSTEM is already elevated.

.PARAMETER HumanReadable
  Switch to output a human‑friendly table/list instead of JSON (intended for interactive testing).

.OUTPUTS
  JSON on STDOUT with keys: Device, KeyCount, Drives, Backups, and optionally Errors.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\backupBitlockerKeys.ps1 -NoElevate
#>

[CmdletBinding()]
param(
  [switch]$NoElevate,
  [switch]$HumanReadable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsElevated {
  try { return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
  catch { return $false }
}

# Elevate in mixed scenarios (CW RMM as SYSTEM is already elevated)
if (-not $NoElevate -and -not (Test-IsElevated)) {
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit 0
  } catch { }
}

function Get-FixedDriveLetters {
  $letters = @()
  try {
    $letters = Get-Volume -ErrorAction Stop |
      Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
      ForEach-Object { $_.DriveLetter.ToString() }
  } catch {
    try {
      $letters = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object { $_.DeviceID -match ':' } |
        ForEach-Object { ($_.DeviceID.Substring(0,1)).ToString() }
    } catch {}
  }
  return @($letters | ForEach-Object { $_.ToString().ToUpper() } | Sort-Object -Unique)
}

function Get-DeviceJoinState {
  $domainJoined = $false
  $azureAdJoined = $false
  try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $domainJoined = [bool]$cs.PartOfDomain
  } catch {}
  try {
    $ds = & dsregcmd.exe /status 2>$null
    if ($ds) { $azureAdJoined = ($ds -match "AzureAdJoined\s*:\s*YES") }
  } catch {}
  [pscustomobject]@{ DomainJoined = $domainJoined; AzureAdJoined = $azureAdJoined }
}

function Get-RecoveryPasswordsFromManageBde {
  param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')] [string]$Drive)
  $present = Test-Path ("${Drive}:")
  if (-not $present) { return @() }
  try {
    $raw = & manage-bde -protectors -get "${Drive}:" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    # Parse blocks that contain ID and Password lines
    $items = @()
    $current = $null
    foreach ($line in $raw) {
      if ($line -match '^\s*ID:\s*\{([0-9A-Fa-f-]{36})\}') {
        $id = $Matches[1]
        $current = [ordered]@{ Id = "{$id}"; Password = $null }
      } elseif ($line -match '^\s*Password:\s*([0-9\- ]{20,})') {
        if ($null -ne $current) {
          $recoveryPwd = ($Matches[1] -replace '\s','').Trim()
          $current.Password = $recoveryPwd
          $items += [pscustomobject]$current
          $current = $null
        }
      }
    }
    return $items
  } catch { return @() }
}

function Invoke-BackupToAD {
  param([string]$Drive, [string]$ProtectorId)
  try {
    $null = & manage-bde -protectors -adbackup "${Drive}:" -id $ProtectorId 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch { return $false }
}

function Invoke-BackupToAAD {
  param([string]$Drive, [string]$ProtectorId)
  $cmd = Get-Command BackupToAAD-BitLockerKeyProtector -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  try {
    BackupToAAD-BitLockerKeyProtector -MountPoint "${Drive}:" -KeyProtectorId $ProtectorId -ErrorAction Stop | Out-Null
    return $true
  } catch { return $false }
}
# Use approved verbs per PowerShell guidelines:
# - "Invoke" for actions (was: Ensure-BackupToAAD, Use-BackupToAAD)
# All function names above now use approved verbs.
function Invoke-BackupToAAD {
  param([string]$Drive, [string]$ProtectorId)
  $cmd = Get-Command BackupToAAD-BitLockerKeyProtector -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  try {
    BackupToAAD-BitLockerKeyProtector -MountPoint "${Drive}:" -KeyProtectorId $ProtectorId -ErrorAction Stop | Out-Null
    return $true
  } catch { return $false }
}
# --- main ---
$errors = @()
try {
  $fixed = Get-FixedDriveLetters
  $join  = Get-DeviceJoinState

  $drivesOut = @{}
  $adAttempted = $false; $adSuccess = 0
  $aadAttempted = $false; $aadSuccess = 0

  foreach ($dl in $fixed) {
    $dl = $dl.ToString()
    $items = Get-RecoveryPasswordsFromManageBde -Drive $dl
    if ($null -eq $items) { $items = @() }
    $items = @($items)
    $drivesOut["$dl"] = [ordered]@{ HasKeys = [bool]($items.Count -gt 0); RecoveryPasswords = $items }

    foreach ($it in $items) {
      if ($join.DomainJoined) {
        $adAttempted = $true
        if (Invoke-BackupToAD -Drive $dl -ProtectorId $it.Id) { $adSuccess++ } else { $errors += "AD escrow failed for $dl $($it.Id)" }
      }
      if ($join.AzureAdJoined) {
        $aadAttempted = $true
        if (Invoke-BackupToAAD -Drive $dl -ProtectorId $it.Id) { $aadSuccess++ } else { $errors += "AAD escrow failed for $dl $($it.Id)" }
      }
    }
  }

  $keyCount = (
    $drivesOut.GetEnumerator() |
    ForEach-Object { @($_.Value.RecoveryPasswords).Count } |
    Measure-Object -Sum
  ).Sum
  if ($null -eq $keyCount) { $keyCount = 0 }

  $payload = [ordered]@{
    Device  = [ordered]@{ DomainJoined = [bool]$join.DomainJoined; AzureAdJoined = [bool]$join.AzureAdJoined }
    KeyCount = [int]$keyCount
    Drives  = $drivesOut
    Backups = [ordered]@{
      ActiveDirectory = [ordered]@{ Attempted = [bool]$adAttempted; Succeeded = [int]$adSuccess }
      AzureAD         = [ordered]@{ Attempted = [bool]$aadAttempted; Succeeded = [int]$aadSuccess }
    }
  }
  if ($errors.Count -gt 0) { $payload.Errors = @($errors) }

  # Build compact JSON of the core payload (no _meta yet)
  $coreJson = $payload | ConvertTo-Json -Depth 6 -Compress

  # Compute SHA256 of the core JSON to help verify integrity/length in RMM
  $sha256 = [System.BitConverter]::ToString(
                ([System.Security.Cryptography.SHA256]::Create()).ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($coreJson)
                )
            ).Replace('-', '').ToLowerInvariant()
  $chars = $coreJson.Length

  # Attach meta (will be included only in the JSON output branch)
  $payload._meta = [ordered]@{ sha256 = $sha256; chars = $chars }

  # Final JSON (core fields + _meta)
  $finalJson = $payload | ConvertTo-Json -Depth 6 -Compress

  if ($HumanReadable) {
    "System Info:"
    $payload.Device | Format-List | Out-String | Write-Output

    "Escrow Status:"
    $payload.Backups | Format-List | Out-String | Write-Output

    "Drives:"
    $payload.Drives.GetEnumerator() | ForEach-Object {
      $k = ($_.Key).ToString()
      "Drive: {0}" -f $k
      $_.Value | Format-List | Out-String | Write-Output
    }
  }
  else {
    # Emit the JSON with _meta so you can verify truncation/integrity in RMM
    Write-Output $finalJson
  }
}
catch {
  Write-Error ("BACKUPBITLOCKERKEYS ERROR: " + $_.Exception.Message)
  exit 1
}

# Success
exit 0
