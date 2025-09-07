#Requires -RunAsAdministrator

<#
.SYNOPSIS
Backup BitLocker Recovery Keys to files and optionally to Active Directory.

.DESCRIPTION
This script exports BitLocker recovery keys for all encrypted volumes on the local machine.
By default, it outputs the recovery information in JSON format to the console.
Use the -WriteFiles switch to save recovery keys to files in the current directory.
Use the -BackupToAD switch to attempt to back up recovery keys to Active Directory.
Use the -Quiet switch to suppress verbose output.

.PARAMETER WriteFiles
Write recovery keys to individual files named by volume.

.PARAMETER BackupToAD
Backup recovery keys to Active Directory (requires AD module and permissions).

.PARAMETER Quiet
Suppress output except for errors.

.EXAMPLE
.\backupBitlockerKeys.ps1
Outputs recovery keys in JSON format.

.EXAMPLE
.\backupBitlockerKeys.ps1 -WriteFiles
Writes recovery keys to files in the current directory.

.EXAMPLE
.\backupBitlockerKeys.ps1 -BackupToAD
Attempts to back up recovery keys to Active Directory.

#>

[CmdletBinding()]
param(
    [switch]$WriteFiles,
    [switch]$BackupToAD,
    [switch]$Quiet
)

function Write-VerboseIf {
    param(
        [string]$Message
    )
    if (-not $Quiet) {
        Write-Verbose $Message
    }
}

try {
    Write-VerboseIf "Retrieving BitLocker volumes..."

    $volumes = Get-BitLockerVolume

    if (-not $volumes) {
        Write-Warning "No BitLocker volumes found."
        exit 0
    }

    $results = @()

    foreach ($vol in $volumes) {
        $volumeLetter = $vol.VolumeLetter
        $keyProtector = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
        if (-not $keyProtector) {
            Write-VerboseIf "No recovery password found for volume $volumeLetter"
            continue
        }

        $recoveryPassword = $keyProtector.RecoveryPassword
        $recoveryKeyId = $keyProtector.KeyProtectorId

        $result = [PSCustomObject]@{
            VolumeLetter     = $volumeLetter
            RecoveryKeyId    = $recoveryKeyId
            RecoveryPassword = $recoveryPassword
        }

        $results += $result

        if ($WriteFiles) {
            $fileName = "BitLockerRecoveryKey_$($volumeLetter.TrimEnd(':')).txt"
            Write-VerboseIf "Writing recovery key for volume $volumeLetter to file $fileName"
            $content = @"
Volume Letter: $volumeLetter
Recovery Key ID: $recoveryKeyId
Recovery Password: $recoveryPassword
"@
            $content | Out-File -FilePath $fileName -Encoding UTF8 -Force
        }

        if ($BackupToAD) {
            Write-VerboseIf "Backing up recovery key for volume $volumeLetter to Active Directory"
            try {
                Backup-BitLockerKeyProtector -MountPoint $volumeLetter -KeyProtectorId $recoveryKeyId -ErrorAction Stop
                Write-VerboseIf "Successfully backed up recovery key for volume $volumeLetter to AD"
            }
            catch {
                Write-Warning "Failed to back up recovery key for volume $volumeLetter to AD: $_"
            }
        }
    }

    if (-not $WriteFiles) {
        $results | ConvertTo-Json -Depth 3 | Write-Output
    }
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}
