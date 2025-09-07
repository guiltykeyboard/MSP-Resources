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

# MSP-Resources

<p align="left">
  <img src="https://img.shields.io/badge/PowerShell-0078d4?logo=powershell&logoColor=white" alt="PowerShell Badge">
  <img src="https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white" alt="Bash Badge">
  <img src="https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=white" alt="Python Badge">
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License Badge">
  <img src="https://github.com/mstoffel/MSP-Resources/actions/workflows/catalog.yml/badge.svg" alt="Catalog Workflow">
  <img src="https://github.com/mstoffel/MSP-Resources/actions/workflows/lint.yml/badge.svg" alt="Lint Workflow">
</p>

## Table of Contents
- [Overview](#overview)
- [Script Catalog](#script-catalog)
- [Recommended Folder Structure](#recommended-folder-structure)
- [Script Documentation Template](#script-documentation-template)
- [License](#license)

## Overview
**MSP-Resources** is a curated collection of scripts and resources for Managed Service Providers (MSPs), IT professionals, and sysadmins. This repository contains reusable automation scripts, tools, and templates designed to streamline IT operations, automate routine tasks, and support best practices across Windows, Linux, and cross-platform environments.

Scripts are provided in PowerShell, Bash, and Python, each with clear documentation and recommended usage scenarios. Contributions and improvements are welcome!

## Script Catalog
<!-- GENERATED-CATALOG:START -->

<!--
  The script catalog below is auto-generated.
  Please do not edit this section manually.
-->

<!-- GENERATED-CATALOG:END -->

## Recommended Folder Structure

```
MSP-Resources/
├── powershell/        # PowerShell scripts (*.ps1)
├── bash/              # Bash scripts (*.sh)
├── python/            # Python scripts (*.py)
├── docs/              # Additional documentation
├── templates/         # Script templates and examples
├── .github/           # GitHub workflows and issue templates
└── README.md          # Project documentation
```

## Script Documentation Template

All scripts should include a header block with essential metadata and usage information. Below is a recommended template (for PowerShell; adapt as needed for Bash or Python):

```powershell
<#
.SYNOPSIS
    Short summary of what the script does.

.DESCRIPTION
    Detailed description of the script, its purpose, and any important details.

.PARAMETER <ParameterName>
    Description of the parameter.

.EXAMPLE
    Example usage of the script.

.NOTES
    Author: Your Name
    Date: YYYY-MM-DD
    Version: 1.0
#>
```

For Bash or Python, provide similar metadata as comments at the top of the script.

## License

This repository is licensed under the [MIT License](LICENSE).