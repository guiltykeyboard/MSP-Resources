<# 
.SYNOPSIS
  Switch Windows 11 Pro Retail -> OEM_DM using embedded OEM key (Win10/11 Pro) and activate.

.DESCRIPTION
  RMM-safe, non-interactive PowerShell script that:
    - Detects embedded OEM key from MSDM (firmware)
    - Skips if already OEM_DM and activated
    - Clears KMS config if present
    - Installs the OEM key and activates online
    - Emits parseable logs and uses deterministic exit codes

.RETURNS
  Exit codes:
    0 = Success (OEM_DM + activated)
    1 = No embedded OEM key found
    2 = General failure / not Pro / could not verify
    3 = Channel switched to OEM_DM but not activated

.NOTES
  - Run as SYSTEM or Admin.
  - No UI; uses cscript //B //nologo.
#>

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "$ts [$Level] $Message"
}

function Get-CurrentLicenseInfo {
    # Select the active Windows license row (has PartialProductKey)
    $win = Get-CimInstance -ClassName SoftwareLicensingProduct |
        Where-Object { $_.Name -like 'Windows*' -and $_.PartialProductKey } |
        Select-Object Name, Description, LicenseStatus, PartialProductKey
    return $win
}

function Invoke-Slmgr {
    param([Parameter(Mandatory)] [string[]]$SlmgrArgs)
    $psi = @{
        FilePath     = "$env:WINDIR\System32\cscript.exe"
        ArgumentList = @('//nologo','//B',"$env:WINDIR\System32\slmgr.vbs") + $SlmgrArgs
        WindowStyle  = 'Hidden'
        Wait         = $true
        PassThru     = $true
    }
    $p = Start-Process @psi
    return $p.ExitCode
}

try {
    Write-Log "Starting Retail → OEM_DM switch + activation."

    # Ensure we're on Professional edition (script targets Pro)
    $editionId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    Write-Log "Detected EditionID: $editionId"
    if ($editionId -ne 'Professional') {
        Write-Log "EditionID is not 'Professional' (current: $editionId). Aborting." 'ERROR'
        exit 2
    }

    # Snapshot current license
    $lic = Get-CurrentLicenseInfo
    if (-not $lic) {
        Write-Log "Unable to read current licensing info." 'ERROR'
        exit 2
    }
    Write-Log ("Current license: {0}; Description: {1}; LicenseStatus: {2}" -f $lic.Name,$lic.Description,$lic.LicenseStatus)

    # If already OEM_DM and activated, nothing to do
    if ($lic.Description -match 'OEM_DM channel' -and $lic.LicenseStatus -eq 1) {
        Write-Log "Already OEM_DM and activated. No action needed."
        exit 0
    }

    # Retrieve embedded OEM key (MSDM table)
    $oemKey = (Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKey
    if (-not $oemKey -or ($oemKey -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$')) {
        Write-Log "No embedded OEM product key found (MSDM) or format invalid. Aborting." 'ERROR'
        exit 1
    }
    Write-Log "Embedded OEM key detected in firmware."

    # If prior Volume/KMS traces exist, clear them so activation uses retail/OEM endpoints
    if ($lic.Description -match 'Volume:GVLK|KMS') {
        Write-Log "Volume/KMS traces detected; clearing KMS configuration."
        [void](Invoke-Slmgr @('/ckms'))
        [void](Invoke-Slmgr @('/skms',''))
    }

    # Install OEM key (replaces current Retail key)
    Write-Log "Installing OEM key..."
    [void](Invoke-Slmgr @('/ipk', $oemKey))

    # Activate online
    Write-Log "Attempting online activation..."
    [void](Invoke-Slmgr @('/ato'))

    # Re-check state
    Start-Sleep -Seconds 3
    $post = Get-CurrentLicenseInfo
    if (-not $post) {
        Write-Log "Unable to refresh license state after activation." 'ERROR'
        exit 2
    }

    Write-Log ("Post-activation: Description: {0}; LicenseStatus: {1}" -f $post.Description,$post.LicenseStatus)
    $isOem = $post.Description -match 'OEM_DM channel'
    $isActivated = $post.LicenseStatus -eq 1

    if ($isOem -and $isActivated) {
        Write-Log "SUCCESS: Channel is OEM_DM and LicenseStatus=1 (activated)."
        exit 0
    } elseif ($isOem -and -not $isActivated) {
        Write-Log "Partial success: Channel switched to OEM_DM but activation not complete." 'WARN'
        exit 3
    } else {
        Write-Log "FAILED: Channel did not switch to OEM_DM or activation failed." 'ERROR'
        exit 2
    }

} catch {
    Write-Log ("Unhandled error: {0}" -f $_.Exception.Message) 'ERROR'
    exit 2
}
