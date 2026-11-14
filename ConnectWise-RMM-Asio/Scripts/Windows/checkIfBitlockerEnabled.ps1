#Requires -Version 5.1
<#
.SYNOPSIS
    Prints exactly one line - 1 or 0 - for whether BitLocker protection is On
    for any fixed (non-removable) drive.

.DESCRIPTION
    Read-only. Emits '1' or '0' on stdout and nothing else, so the caller's
    single-line match is unambiguous. When the state cannot be determined it
    prints NOTHING and exits non-zero, so no caller can record a guess as an
    answer.

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
      2  could not determine (system volume unreadable, no fixed drives)
      1  unexpected error
    Version: 2.0.0
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$SelfUpdated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

        Get-BitLockerVolume first, manage-bde as the fallback for hosts where
        the BitLocker module is absent.
    #>
    param([Parameter(Mandatory)][string]$Drive)

    $mount = '{0}:' -f $Drive

    if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            $vol = Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop
            if ($null -ne $vol -and $vol.PSObject.Properties.Name -contains 'ProtectionStatus') {
                $state = [string]$vol.ProtectionStatus
                if ($state -eq 'On' -or $state -eq 'Off') { return $state }
            }
        }
        catch { }
    }

    try {
        # Check the output first: if manage-bde is absent the exit code is stale.
        $raw = & manage-bde -status $mount 2>$null
        if (-not $raw) { return 'Unknown' }

        $hit = $raw | Select-String -Pattern 'Protection\s*Status\s*:\s*(.+)$' | Select-Object -First 1
        if ($null -eq $hit) { return 'Unknown' }

        $value = $hit.Matches[0].Groups[1].Value.Trim()
        if ($value -match '^On')  { return 'On' }
        if ($value -match '^Off') { return 'Off' }
    }
    catch { }

    return 'Unknown'
}

try {
    $drives = @(Get-FixedDriveLetters)
    if ($drives.Count -eq 0) {
        [Console]::Error.WriteLine('BL_CHECK: no fixed drives enumerated')
        exit 2
    }

    $systemDrive = ''
    if ($env:SystemDrive) {
        $systemDrive = $env:SystemDrive.TrimEnd('\').TrimEnd(':').ToUpperInvariant()
    }

    $anyKnown = $false
    $anyOn    = $false

    foreach ($drive in $drives) {
        if (-not (Test-Path -LiteralPath ('{0}:\' -f $drive))) { continue }

        $state = Get-ProtectionState -Drive $drive

        switch ($state) {
            'On'  { $anyKnown = $true; $anyOn = $true }
            'Off' { $anyKnown = $true }
            default {
                # The system volume is the one that matters. If its state is
                # unreadable, guessing '0' would be a false negative.
                if ($drive -eq $systemDrive) {
                    [Console]::Error.WriteLine(('BL_CHECK: protection state unknown for {0}:' -f $drive))
                    exit 2
                }
            }
        }
    }

    if (-not $anyKnown) {
        [Console]::Error.WriteLine('BL_CHECK: protection state unknown for all fixed drives')
        exit 2
    }

    Write-Output ([int]$anyOn)
    exit 0
}
catch {
    [Console]::Error.WriteLine('BL_CHECK: ' + $_.Exception.Message)
    exit 1
}
