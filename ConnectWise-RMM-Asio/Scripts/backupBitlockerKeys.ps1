#Requires -RunAsAdministrator
#Requires -Version 5.1
<#!
.SYNOPSIS
  Backup and inventory BitLocker recovery keys on this device.
.DESCRIPTION
  Designed for ConnectWise RMM (Asio) but runs standalone. Emits a compact JSON object (and a table)
  by default for RMM ingestion; optional file exports with -WriteFiles.
.PARAMETER WriteFiles
  Write TXT/CSV/JSON artifacts to disk (opt-in)
.PARAMETER OutputRoot
  Folder to write artifacts when -WriteFiles is used
.PARAMETER AttemptADBackup
  If domain-joined, attempt AD DS backup of each recovery protector
.PARAMETER Quiet
  JSON-only output (no table/log lines)
.EXITCODES
  0 success; 2 no recovery passwords found; 1 error
#!>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
  [switch]$WriteFiles,                 # Opt-in: write TXT/CSV/JSON to disk
  [string]$OutputRoot = 'C:\\ProgramData\\CW-RMM\\BitLocker',
  [switch]$AttemptADBackup,            # If domain-joined, call Backup-BitLockerKeyProtector
  [switch]$Quiet                       # If set, emit JSON only
)

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts][$Level] $Message"
}

try {
  $hostname   = $env:COMPUTERNAME
  $serial     = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
  if (-not $serial) { $serial = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).IdentifyingNumber }

  if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
    throw 'Get-BitLockerVolume cmdlet not found. This Windows edition may not include BitLocker tools.'
  }

  $volumes = Get-BitLockerVolume | Where-Object { $_.VolumeType -in 'OperatingSystem','Data' }

  $rows = @()
  $anyRecovery = $false

  foreach ($vol in $volumes) {
    $mp      = $vol.MountPoint
    $enc     = $vol.EncryptionPercentage
    $volType = $vol.VolumeType
    $kps     = $vol.KeyProtector

    $recKPs = @()
    if ($kps) { $recKPs = $kps | Where-Object { $_.KeyProtectorType -in 'RecoveryPassword','NumericalPassword' } }
    if ($recKPs.Count -gt 0) { $anyRecovery = $true }

    if ($recKPs.Count -eq 0) {
      $rows += [pscustomobject]@{
        ComputerName       = $hostname
        SerialNumber       = $serial
        VolumeType         = $volType
        MountPoint         = $mp
        ProtectionStatus   = $vol.ProtectionStatus
        EncryptionPercent  = $enc
        KeyProtectorType   = $null
        RecoveryKeyId      = $null
        RecoveryPassword   = $null
        BackedUpToAD       = $false
        Timestamp          = (Get-Date)
      }
      continue
    }

    foreach ($kp in $recKPs) {
      $recoveryId  = $kp.KeyProtectorId
      $recoveryPwd = $null

      # Extract recovery password via manage-bde for reliability across builds
      try {
        $mbde = manage-bde -protectors -get $mp 2>$null
        $inBlock = $false
        foreach ($line in $mbde) {
          if ($line -match 'ID:\s*\{?'+[regex]::Escape($recoveryId)+'\}?') { $inBlock = $true; continue }
          if ($inBlock -and $line -match 'Password:\s*(?<pwd>[0-9\- ]{20,})') {
            $recoveryPwd = ($Matches['pwd'] -replace '\s','').Trim()
            break
          }
          if ($inBlock -and [string]::IsNullOrWhiteSpace($line)) { break }
        }
      } catch { }

      if (-not $recoveryPwd -and $kp.NumericalPassword) { $recoveryPwd = ($kp.NumericalPassword -replace '\s','').Trim() }

      $backedUp = $false
      if ($AttemptADBackup.IsPresent) {
        try {
          $cs = Get-CimInstance Win32_ComputerSystem
          if ($cs.PartOfDomain) {
            Write-Log "Attempting AD DS backup for $mp protector $recoveryId..."
            Backup-BitLockerKeyProtector -MountPoint $mp -KeyProtectorId $recoveryId -ErrorAction Stop | Out-Null
            $backedUp = $true
          } else {
            Write-Log 'Machine is not domain-joined; skipping AD backup.' 'WARN'
          }
        } catch {
          Write-Log "AD backup attempt failed for $mp protector $recoveryId: $($_.Exception.Message)" 'WARN'
        }
      }

      $rows += [pscustomobject]@{
        ComputerName       = $hostname
        SerialNumber       = $serial
        VolumeType         = $volType
        MountPoint         = $mp
        ProtectionStatus   = $vol.ProtectionStatus
        EncryptionPercent  = $enc
        KeyProtectorType   = $kp.KeyProtectorType
        RecoveryKeyId      = $recoveryId
        RecoveryPassword   = $recoveryPwd
        BackedUpToAD       = $backedUp
        Timestamp          = (Get-Date)
      }
    }
  }

  $summary = [pscustomobject]@{
    ComputerName = $hostname
    SerialNumber = $serial
    AnyRecovery  = [bool]$anyRecovery
    Count        = $rows.Count
    Timestamp    = Get-Date
    Rows         = $rows
  }

  if ($Quiet) {
    $summary | ConvertTo-Json -Depth 6 -Compress | Write-Output
  } else {
    Write-Host '==== BitLocker Recovery Summary (table) ===='
    $rows | Select-Object ComputerName,MountPoint,KeyProtectorType,RecoveryKeyId,RecoveryPassword,BackedUpToAD |
      Format-Table -AutoSize | Out-String | Write-Host
    Write-Host '==== BitLocker Recovery Summary (json) ===='
    $summary | ConvertTo-Json -Depth 6 -Compress | Write-Output
  }

  if ($WriteFiles) {
    try {
      if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
      $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
      $txtPath  = Join-Path $OutputRoot "${hostname}_${timestamp}_BitLocker.txt"
      $csvPath  = Join-Path $OutputRoot "${hostname}_${timestamp}_BitLocker.csv"
      $jsonPath = Join-Path $OutputRoot "${hostname}_${timestamp}_BitLocker.json"

      $rows | Sort-Object MountPoint, KeyProtectorType | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
      $rows | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8
      ($rows | Select-Object ComputerName,MountPoint,KeyProtectorType,RecoveryKeyId,RecoveryPassword,BackedUpToAD |
        Format-Table -AutoSize | Out-String) | Out-File -FilePath $txtPath -Encoding UTF8

      Write-Log "Wrote: $csvPath"
      Write-Log "Wrote: $jsonPath"
      Write-Log "Wrote: $txtPath"
    } catch {
      Write-Log "Optional file export failed: $($_.Exception.Message)" 'WARN'
    }
  }

  if ($rows.Count -eq 0 -or -not $anyRecovery) { exit 2 } else { exit 0 }
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
  exit 1
}
