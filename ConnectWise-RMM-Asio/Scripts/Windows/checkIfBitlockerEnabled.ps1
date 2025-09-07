#Requires -Version 5.1
<#
.SYNOPSIS
  Detect whether BitLocker is enabled on drives C, D, E, and F.
.DESCRIPTION
  Designed for ConnectWise RMM (Asio). The script runs safely as SYSTEM; for mixed
  scenarios it will elevate to administrator when not already running elevated.
  It checks the BitLocker protection state for the fixed drives C, D, E, and F (if present)
  using `Get-BitLockerVolume` when available, and falls back to parsing
  `manage-bde -status` on systems without the BitLocker module. No local files are created.

  Output is a compact JSON object to STDOUT for easy parsing by RMM. A human‑readable
  table is also printed unless `-Quiet` is supplied.

.PARAMETER Quiet
  Suppress the human‑readable table and only emit JSON.

.PARAMETER NoElevate
  Skip the self‑elevation step (useful if the host blocks UAC prompts in interactive runs).

.OUTPUTS
  JSON (string) describing per‑drive status and a summary flag.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\checkIfBitlockerEnabled.ps1 -Quiet
  # {"AnyEnabled":true,"Drives":{"C":{"Present":true,"Protection":"On","EncryptionPercentage":100,"Enabled":true},...}}
#>

param(
  [switch]$Quiet,
  [switch]$NoElevate
)

function Test-IsElevated {
  try { return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
  catch { return $false }
}

# Mixed environments: elevate if needed (RMM usually runs as SYSTEM which is elevated)
if (-not $NoElevate -and -not (Test-IsElevated)) {
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($MyInvocation.BoundParameters.GetEnumerator() | ForEach-Object { if ($_.Value) { '-'+$_.Key } })" -Verb RunAs
    exit 0
  } catch {
    Write-Warning "Elevation failed or was canceled; continuing without elevation."
  }
}

$targets = 'C','D','E','F'

function Get-BitLockerInfo {
  param([string[]]$DriveLetters)
  $result = @{}

  $blCmdlet = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
  if ($blCmdlet) {
    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    foreach ($dl in $DriveLetters) {
      $present = Test-Path ("${dl}:\")
      $info = [ordered]@{ Present = $present; Protection = $null; EncryptionPercentage = $null; Enabled = $false }
      if ($present) {
        $v = $vols | Where-Object { $_.MountPoint -eq "${dl}:\\" }
        if ($null -ne $v) {
          $info.Protection = ($v.ProtectionStatus | ForEach-Object { $_.ToString() })
          $info.EncryptionPercentage = $v.EncryptionPercentage
          $info.Enabled = ($v.ProtectionStatus -eq 'On')
        } else {
          # Volume exists but not returned (unlikely) – fallback to manage-bde for this drive
          $info = (Get-ManageBdeFallback -Drive $dl)
        }
      }
      $result[$dl] = $info
    }
  } else {
    foreach ($dl in $DriveLetters) {
      $result[$dl] = (Get-ManageBdeFallback -Drive $dl)
    }
  }
  return $result
}

function Get-ManageBdeFallback {
  param([Parameter(Mandatory)] [ValidatePattern('^[A-Fa-f]$')] [string]$Drive)
  $present = Test-Path ("${Drive}:\")
  $info = [ordered]@{ Present = $present; Protection = $null; EncryptionPercentage = $null; Enabled = $false }
  if (-not $present) { return $info }
  try {
    $raw = & manage-bde -status "${Drive}:\\" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $info }
    $prot = ($raw | Select-String -Pattern 'Protection Status:\s*(.*)' -AllMatches | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Select-Object -First 1)
    $pct  = ($raw | Select-String -Pattern 'Percentage Encrypted:\s*(\d+)' -AllMatches | ForEach-Object { [int]$_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    if (-not $pct) { $pct = $null }
    $info.Protection = $prot
    $info.EncryptionPercentage = $pct
    $info.Enabled = ($prot -match 'On')
  } catch { }
  return $info
}

$driveInfo = Get-BitLockerInfo -DriveLetters $targets
$anyEnabled = ($driveInfo.GetEnumerator() | Where-Object { $_.Value.Enabled } | Measure-Object).Count -gt 0

# Human-friendly output unless -Quiet
if (-not $Quiet) {
  $table = foreach ($k in $targets) {
    $v = $driveInfo[$k]
    [pscustomobject]@{
      Drive = $k
      Present = $v.Present
      Protection = $v.Protection
      EncryptionPercent = $v.EncryptionPercentage
      Enabled = $v.Enabled
    }
  }
  $table | Format-Table -AutoSize | Out-String | Write-Output
}

# JSON payload for RMM
$payload = [ordered]@{
  AnyEnabled = $anyEnabled
  Drives     = $driveInfo
}
$payload | ConvertTo-Json -Depth 5 -Compress | Write-Output

# Always exit 0 for detection runs; consumers should inspect JSON
exit 0