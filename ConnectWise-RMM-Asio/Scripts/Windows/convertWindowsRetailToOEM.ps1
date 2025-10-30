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
    # Filter precisely to the Windows OS licensing row for Professional that has a key
    $WindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f' # Windows OS ApplicationId
    $win = Get-CimInstance -ClassName SoftwareLicensingProduct |
        Where-Object {
            $_.ApplicationId -eq $WindowsAppId -and
            $_.LicenseFamily -match 'Professional' -and
            $_.PartialProductKey
        } |
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

# Optional: allow last-resort DISM edition repair when ALLOW_DISM_REPAIR is true/1
$AllowDismRepair = [bool]($env:ALLOW_DISM_REPAIR -as [int]) -or ($env:ALLOW_DISM_REPAIR -eq 'true')

try {
    Write-Log "Starting Retail -> OEM_DM switch + activation."

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

    # If Retail/KMS residue is present, perform a clean key reset
    if ($lic.Description -match 'RETAIL channel' -or $lic.Description -match 'Volume:GVLK|KMS') {
        Write-Log "Resetting prior key state (upk/cpky, sppsvc restart, rebuild license files)."
        try { [void](Invoke-Slmgr @('/upk')) } catch {}
        try { [void](Invoke-Slmgr @('/cpky')) } catch {}
        try {
            Write-Log "Restarting Software Protection service (sppsvc)."
            Stop-Service -Name sppsvc -Force -ErrorAction SilentlyContinue
            Start-Service -Name sppsvc -ErrorAction SilentlyContinue
        } catch {}
        try { [void](Invoke-Slmgr @('/rilc')) } catch {}
    }
    # Install OEM key (replaces current Retail key)
    Write-Log "Installing OEM key..."
    [void](Invoke-Slmgr @('/ipk', $oemKey))

    # Activate online
    Write-Log "Attempting online activation..."
    [void](Invoke-Slmgr @('/ato'))

    # Re-check state with retries (sppsvc/WMI can lag after key/activation changes)
    $retryMax = 10
    $retryDelay = 6
    $post = $null
    for ($i = 1; $i -le $retryMax; $i++) {
        try {
            $post = Get-CurrentLicenseInfo
        } catch {
            $post = $null
        }
        if ($post) { break }
        Write-Log "License state not available yet (attempt $i/$retryMax). Waiting ${retryDelay}s..."
        Start-Sleep -Seconds $retryDelay
    }
    if (-not $post) {
        Write-Log "Unable to refresh license state after activation (after $retryMax attempts)." 'ERROR'
        exit 2
    }

    Write-Log ("Post-activation: Description: {0}; LicenseStatus: {1}" -f $post.Description,$post.LicenseStatus)
    $isOem = $post.Description -match 'OEM_DM channel'
    $isActivated = $post.LicenseStatus -eq 1

    if (-not $isOem -or -not $isActivated) {
        Write-Log "Primary activation did not succeed. Trying WMI InstallProductKey + re-activation."
        try {
            $svc = Get-CimInstance -ClassName SoftwareLicensingService
            [void]($svc.InstallProductKey($oemKey))
            [void](Invoke-Slmgr @('/ato'))
            Start-Sleep -Seconds 3
            $post = Get-CurrentLicenseInfo
            if ($post) {
                Write-Log ("Post-fallback: Description: {0}; LicenseStatus: {1}" -f $post.Description,$post.LicenseStatus)
                $isOem = $post.Description -match 'OEM_DM channel'
                $isActivated = $post.LicenseStatus -eq 1
            }
        } catch {
            Write-Log ("WMI InstallProductKey path failed: {0}" -f $_.Exception.Message) 'WARN'
        }
    }

    if ($isOem -and $isActivated) {
        Write-Log "SUCCESS: Channel is OEM_DM and LicenseStatus=1 (activated)."
        exit 0
    } elseif ($isOem -and -not $isActivated) {
        Write-Log "Partial success: Channel switched to OEM_DM but activation not complete." 'WARN'
        exit 3
    } else {
        Write-Log "FAILED: Channel did not switch to OEM_DM or activation failed." 'ERROR'
        if ($AllowDismRepair) {
            Write-Log "ALLOW_DISM_REPAIR enabled. Attempting DISM edition repair to 'Professional' with OEM key (may require reboot)."
            try {
                Start-Process -FilePath dism.exe -ArgumentList "/online","/Set-Edition:Professional","/ProductKey:$oemKey","/AcceptEula" -Wait -NoNewWindow
                Write-Log "DISM completed. A reboot may be required. Re-run activation after reboot if needed."
            } catch {
                Write-Log ("DISM repair failed: {0}" -f $_.Exception.Message) 'WARN'
            }
        }
        exit 2
    }

} catch {
    Write-Log ("Unhandled error: {0}" -f $_.Exception.Message) 'ERROR'
    exit 2
}
