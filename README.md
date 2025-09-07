#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Backup BitLocker recovery keys to a JSON file and optionally to Active Directory.

.DESCRIPTION
    This script exports BitLocker recovery key information for all encrypted drives on the local computer.
    By default, it outputs the recovery key information in JSON format to the console.
    Use the -WriteFiles parameter to save each recovery key to a separate file in the current directory.
    Use the -BackupToAD switch to attempt to back up the recovery keys to Active Directory.
    The -Quiet switch suppresses output except for errors.

.PARAMETER WriteFiles
    Saves each recovery key to a separate .txt file named after the volume drive letter.

.PARAMETER BackupToAD
    Attempts to back up the recovery key to Active Directory for each volume.

.PARAMETER Quiet
    Suppresses output except for errors.

.EXAMPLE
    .\backupBitlockerKeys.ps1 -WriteFiles

    Outputs the recovery keys to separate files in the current directory.

.EXAMPLE
    .\backupBitlockerKeys.ps1 -BackupToAD

    Tries to back up the recovery keys to Active Directory.

.EXAMPLE
    .\backupBitlockerKeys.ps1 -Quiet

    Outputs only errors.

#>

[CmdletBinding()]
param(
    [switch]$WriteFiles,
    [switch]$BackupToAD,
    [switch]$Quiet
)

function Write-Log {
    param (
        [string]$Message,
        [switch]$Error
    )
    if (-not $Quiet -or $Error) {
        if ($Error) {
            Write-Error $Message
        }
        else {
            Write-Output $Message
        }
    }
}

try {
    $bitlockerVolumes = Get-BitLockerVolume | Where-Object { $_.KeyProtector -ne $null }
}
catch {
    Write-Log "Failed to retrieve BitLocker volumes. Are you running as Administrator?" -Error
    exit 1
}

if (-not $bitlockerVolumes) {
    Write-Log "No BitLocker volumes found or no key protectors present."
    exit 0
}

$results = @()

foreach ($vol in $bitlockerVolumes) {
    $volumeLetter = $vol.VolumeLetter
    $recoveryKeyProtector = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }

    if (-not $recoveryKeyProtector) {
        Write-Log "No recovery password protector found for volume $volumeLetter."
        continue
    }

    $recoveryKey = $recoveryKeyProtector.RecoveryPassword

    $result = [PSCustomObject]@{
        VolumeLetter       = $volumeLetter
        RecoveryKey        = $recoveryKey
        ProtectionStatus   = $vol.ProtectionStatus
        LockStatus         = $vol.LockStatus
        EncryptionMethod   = $vol.EncryptionMethod
        AutoUnlockEnabled  = $vol.AutoUnlockEnabled
        KeyProtectorType   = $recoveryKeyProtector.KeyProtectorType
        RecoveryKeyId      = $recoveryKeyProtector.RecoveryKeyId
    }

    $results += $result

    if ($WriteFiles) {
        $fileName = "BitLockerRecoveryKey_$volumeLetter.txt"
        try {
            $recoveryKey | Out-File -FilePath $fileName -Encoding ASCII -Force
            Write-Log "Saved recovery key for volume $volumeLetter to file $fileName"
        }
        catch {
            Write-Log "Failed to write recovery key file for volume $volumeLetter: $_" -Error
        }
    }

    if ($BackupToAD) {
        try {
            Backup-BitLockerKeyProtector -MountPoint $volumeLetter -KeyProtectorId $recoveryKeyProtector.KeyProtectorId -ErrorAction Stop
            Write-Log "Backed up recovery key for volume $volumeLetter to Active Directory."
        }
        catch {
            Write-Log "Failed to back up recovery key to Active Directory for volume $volumeLetter: $_" -Error
        }
    }
}

if (-not $WriteFiles) {
    $results | ConvertTo-Json -Depth 3
}
