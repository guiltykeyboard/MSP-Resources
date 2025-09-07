<file name=ConnectWise-RMM-Asio/Scripts/backupBitlockerKeys.ps1>#requires -RunAsAdministrator
<#
.SYNOPSIS
    Backup BitLocker recovery keys and export recovery information.

.DESCRIPTION
    This script enumerates BitLocker volumes and extracts recovery passwords and key protector IDs.
    Optionally attempts to back up recovery keys to Active Directory if domain joined.
    By default, outputs JSON and a compact table to the console. Writing to files is opt-in.

.PARAMETER WriteFiles
    Switch to opt-in writing TXT/CSV/JSON artifacts and transcript to disk.

.PARAMETER OutputRoot
    Directory path for output artifacts when WriteFiles is specified. Default: C:\ProgramData\CW-RMM\BitLocker

.PARAMETER AttemptADBackup
    Switch to attempt backup of recovery key protectors to Active Directory (domain-joined only).

.PARAMETER Quiet
    Switch to emit JSON only (no table/log style output).

.EXAMPLE
    .\backupBitlockerKeys.ps1 -WriteFiles -AttemptADBackup

.EXAMPLE
    .\backupBitlockerKeys.ps1 -Quiet

#>

param(
    [switch]$WriteFiles,                 # Opt-in: write TXT/CSV/JSON + transcript to disk
    [string]$OutputRoot = 'C:\ProgramData\CW-RMM\BitLocker',
    [switch]$AttemptADBackup,            # If domain-joined and supported, will call Backup-BitLockerKeyProtector
    [switch]$Quiet                       # If set, emit JSON only (no table/log style output)
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts][$Level] $Message"
}

$ErrorActionPreference = 'Stop'

try {
    $hostname = $env:COMPUTERNAME
    $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()

    # Collect BitLocker volumes info
    $volumes = Get-BitLockerVolume

    $rows = @()
    $anyRecovery = $false

    foreach ($vol in $volumes) {
        $mount = $vol.MountPoint
        $protectors = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
        foreach ($prot in $protectors) {
            $anyRecovery = $true
            # Attempt AD backup if requested and domain joined
            $backedUp = $false
            if ($AttemptADBackup) {
                try {
                    Backup-BitLockerKeyProtector -MountPoint $mount -KeyProtectorId $prot.KeyProtectorId -ErrorAction Stop
                    $backedUp = $true
                } catch {
                    Write-Log "Failed AD backup for $mount protector $($prot.KeyProtectorId): $($_.Exception.Message)" 'WARN'
                }
            }
            $rows += [pscustomobject]@{
                ComputerName      = $hostname
                SerialNumber      = $serial
                MountPoint        = $mount
                KeyProtectorType  = $prot.KeyProtectorType
                RecoveryKeyId     = $prot.KeyProtectorId
                RecoveryPassword  = $prot.RecoveryPassword
                BackedUpToAD     = $backedUp
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

    # Default behavior for RMM (running as SYSTEM): no files, emit JSON and a compact table
    if ($Quiet) {
        $summary | ConvertTo-Json -Depth 6 -Compress | Write-Output
    } else {
        Write-Host '==== BitLocker Recovery Summary (table) ===='
        $rows | Select-Object ComputerName,MountPoint,KeyProtectorType,RecoveryKeyId,RecoveryPassword,BackedUpToAD | Format-Table -AutoSize | Out-String | Write-Host
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
            ($rows | Select-Object ComputerName,MountPoint,KeyProtectorType,RecoveryKeyId,RecoveryPassword,BackedUpToAD | Format-Table -AutoSize | Out-String) | Out-File -FilePath $txtPath -Encoding UTF8
            Write-Log "Wrote: $csvPath"
            Write-Log "Wrote: $jsonPath"
            Write-Log "Wrote: $txtPath"
        } catch {
            Write-Log "Optional file export failed: $($_.Exception.Message)" 'WARN'
        }
    }

    if ($rows.Count -eq 0 -or -not $anyRecovery) { exit 2 } else { exit 0 }
} catch {
    Write-Log "Error: $($_.Exception.Message)" 'ERROR'
    exit 1
}
</file>
