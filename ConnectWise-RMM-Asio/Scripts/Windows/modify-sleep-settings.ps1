<#
.SYNOPSIS
  Prevents Windows from sleeping when plugged in (AC) without changing battery behavior.
.DESCRIPTION
  Runs as SYSTEM or Administrator, targets the active power plan, and sets AC sleep/hibernate
  timeouts to 0 (Never). Battery/DC settings are left untouched. Suitable for CW RMM maintenance
  windows that need devices awake overnight.
#>

[CmdletBinding()]
param(
    [bool]$SetNeverSleepOnAC = $true,
    [bool]$SetNeverHibernateOnAC = $true
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "$ts [$Level] $Message"
}

function Test-Elevation {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Script should run elevated (SYSTEM/Admin). Detected non-elevated context." "WARN"
    }
}

function Get-ActiveScheme {
    $out = powercfg /getactivescheme 2>$null
    if (-not $out) { throw "Could not read active power scheme." }
    if ($out -match 'GUID:\\s*([a-fA-F0-9-]+)') {
        return $Matches[1]
    }
    throw "Failed to parse active power scheme GUID."
}

function Set-AcNoSleep {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [string]$SchemeGuid,
        [bool]$SetSleep = $true,
        [bool]$SetHibernate = $true
    )
    if (-not $SetSleep -and -not $SetHibernate) {
        Write-Log "No AC changes requested; skipping powercfg updates." "WARN"
        return
    }

    Write-Log "Applying AC sleep/hibernate = Never on scheme $SchemeGuid"

    if ($PSCmdlet.ShouldProcess("AC power settings", "Set sleep/hibernate to Never for scheme $SchemeGuid")) {
        if ($SetSleep) {
            powercfg /change standby-timeout-ac 0 | Out-Null
            powercfg /setacvalueindex $SchemeGuid SUB_SLEEP STANDBYIDLE 0 | Out-Null
        }
        if ($SetHibernate) {
            powercfg /change hibernate-timeout-ac 0 | Out-Null
            powercfg /setacvalueindex $SchemeGuid SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
        }

        # Re-activate to ensure changes take effect
        powercfg /setactive $SchemeGuid | Out-Null
    }
}

try {
    Test-Elevation
    $scheme = Get-ActiveScheme
    Set-AcNoSleep -SchemeGuid $scheme -SetSleep:$SetNeverSleepOnAC -SetHibernate:$SetNeverHibernateOnAC
    Write-Log "Success: Sleep/hibernate on AC set to Never; battery settings untouched."
    exit 0
}
catch {
    Write-Log "Error: $_" "ERROR"
    exit 1
}
