#Requires -Version 5.1
<#
.SYNOPSIS
    Prints exactly one line - 1 or 0 - for whether BitLocker protection is On
    for any fixed (non-removable) drive.

.DESCRIPTION
    Read-only. Emits '1' or '0' on stdout and nothing else, so the caller's
    single-line match is unambiguous. When the state cannot be determined it
    prints NOTHING on stdout, writes a machine-readable reason to stderr, and
    exits non-zero - so no caller can record a guess as an answer, and the
    reason for the silence survives into the RMM script log.

    No network access. No self-update. No files written. No elevation.

    The previous version of this script carried a self-updater that compared a
    40-character baked commit constant against a 7-character short SHA, so it
    concluded "outdated" on every run, re-launched itself from %TEMP, and
    exited before printing the 0/1 line. That path is gone: pin the fetch to a
    commit SHA instead (see rmm-check-bitlocker-wrapper.ps1) and the content can
    never be stale, because content at a SHA is immutable.

.PARAMETER NoElevate
    Accepted for backward compatibility. This script never self-elevates; run
    it as SYSTEM (RMM agents already do).

.PARAMETER SelfUpdated
    Accepted for backward compatibility. Unused.

.OUTPUTS
    System.String - '1' or '0' on stdout, one line.

.NOTES
    Exit codes:
      0  verdict emitted
      2  could not determine - a BL_REASON= line on stderr says why
      1  unexpected error

    stderr reasons:
      NO_BITLOCKER_CMDLETS   neither Get-BitLockerVolume nor manage-bde exists
      NO_DRIVES              no fixed drives enumerated
      SYSTEM_VOLUME_UNKNOWN  the system volume's state could not be read
      ALL_DRIVES_UNKNOWN     no fixed drive yielded a readable state
      UNEXPECTED             an exception escaped; detail carries the message
    Version: 2.1.0
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$SelfUpdated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Reason {
    <#
        Machine-readable reason on stderr, never on stdout. stdout carries the
        verdict and nothing else; the caller relays these lines to the log.
    #>
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string]$Detail
    )

    [Console]::Error.WriteLine('BL_REASON=' + $Reason)
    if ($Detail) {
        [Console]::Error.WriteLine('BL_DETAIL=' + ($Detail -replace '[\r\n]+', ' '))
    }
}

function Get-FixedDriveLetters {
    <#
        Letters of fixed/local volumes only. Removable, optical, network and
        RAM disks are excluded so a plugged-in USB stick cannot flip the result.
    #>
    $letters = @()
    try {
        $letters = @(Get-Volume -ErrorAction Stop |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
            Select-Object -ExpandProperty DriveLetter)
    }
    catch {
        try {
            $letters = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                Where-Object { $_.DeviceID -match '^[A-Za-z]:$' } |
                ForEach-Object { $_.DeviceID.Substring(0, 1) })
        }
        catch { $letters = @() }
    }

    return @($letters |
        Where-Object { $_ } |
        ForEach-Object { $_.ToString().ToUpperInvariant() } |
        Sort-Object -Unique)
}

function Get-ProtectionState {
    <#
        Returns 'On', 'Off' or 'Unknown'. Never throws.
    #>
    param(
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][bool]$HasBitLockerCmdlet,
        [Parameter(Mandatory)][bool]$HasManageBde
    )

    $mount = '{0}:' -f $Drive

    if ($HasBitLockerCmdlet) {
        try {
            $vol = Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop
            if ($null -ne $vol -and $vol.PSObject.Properties.Name -contains 'ProtectionStatus') {
                $state = [string]$vol.ProtectionStatus
                if ($state -eq 'On' -or $state -eq 'Off') { return $state }
            }
        }
        catch { }
    }

    if ($HasManageBde) {
        try {
            # Check the output first: if manage-bde failed to start, the exit
            # code left behind is from whatever ran before it.
            $raw = & manage-bde -status $mount 2>$null
            if ($raw) {
                $hit = $raw | Select-String -Pattern 'Protection\s*Status\s*:\s*(.+)$' | Select-Object -First 1
                if ($null -ne $hit) {
                    $value = $hit.Matches[0].Groups[1].Value.Trim()
                    if ($value -match '^On')  { return 'On' }
                    if ($value -match '^Off') { return 'Off' }
                }
            }
        }
        catch { }
    }

    return 'Unknown'
}

try {
    $hasBlCmd  = [bool](Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)
    $hasManage = [bool](Get-Command -Name manage-bde -ErrorAction SilentlyContinue)

    if (-not $hasBlCmd -and -not $hasManage) {
        Write-Reason -Reason 'NO_BITLOCKER_CMDLETS' `
            -Detail 'neither Get-BitLockerVolume nor manage-bde is available on this host'
        exit 2
    }

    $drives = @(Get-FixedDriveLetters)
    if ($drives.Count -eq 0) {
        Write-Reason -Reason 'NO_DRIVES' -Detail 'Get-Volume and Win32_LogicalDisk both returned no fixed volumes'
        exit 2
    }

    $systemDrive = ''
    if ($env:SystemDrive) {
        $systemDrive = $env:SystemDrive.TrimEnd('\').TrimEnd(':').ToUpperInvariant()
    }

    $anyKnown = $false
    $anyOn    = $false
    $unknown  = @()

    foreach ($drive in $drives) {
        if (-not (Test-Path -LiteralPath ('{0}:\' -f $drive))) { continue }

        $state = Get-ProtectionState -Drive $drive -HasBitLockerCmdlet $hasBlCmd -HasManageBde $hasManage

        switch ($state) {
            'On'  { $anyKnown = $true; $anyOn = $true }
            'Off' { $anyKnown = $true }
            default {
                # The system volume is the one that matters. If its state is
                # unreadable, guessing '0' would be a false negative.
                if ($drive -eq $systemDrive) {
                    Write-Reason -Reason 'SYSTEM_VOLUME_UNKNOWN' `
                        -Detail ('{0}: could not be read (Get-BitLockerVolume available: {1}; manage-bde available: {2})' -f $drive, $hasBlCmd, $hasManage)
                    exit 2
                }
                $unknown += $drive
            }
        }
    }

    if (-not $anyKnown) {
        $detail = 'no fixed drive yielded a readable protection state'
        if ($unknown.Count -gt 0) { $detail = 'unreadable: ' + ($unknown -join ', ') }
        Write-Reason -Reason 'ALL_DRIVES_UNKNOWN' -Detail $detail
        exit 2
    }

    Write-Output ([int]$anyOn)
    exit 0
}
catch {
    Write-Reason -Reason 'UNEXPECTED' -Detail $_.Exception.Message
    exit 1
}
