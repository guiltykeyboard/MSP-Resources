<#
.SYNOPSIS
  Sets Adobe Acrobat Reader as the default PDF handler on Windows 10/11.
.DESCRIPTION
  Detects an installed Acrobat Reader, builds a default-app associations XML,
  and imports it system-wide. Intended for ConnectWise RMM or any RMM running
  PowerShell as SYSTEM.
#>
# Set Acrobat Reader as the default PDF app (Windows 10/11)
# Works via ConnectWise RMM / any RMM that executes PowerShell as System.

$ErrorActionPreference = 'SilentlyContinue'

function Get-AcrobatReaderProgId {
    # Common ProgIDs for Adobe Reader
    $candidateProgIds = @(
        'AcroExch.Document.DC',     # Reader DC
        'AcroExch.Document',        # Legacy Reader
        'AcroExch.Document.7',      # Older Reader
        'Acrobat.Document.DC'       # Rare variants
    )

    # Check HKCR (merged view) for existing ProgID registrations
    foreach ($progIdCandidate in $candidateProgIds) {
        if (Test-Path "HKCR:\$progIdCandidate") { return $progIdCandidate }
    }

    # Fallback: try to read from Adobe Reader uninstall keys and infer
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($path in $paths) {
        $items = Get-ItemProperty -Path ($path + '\*') -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Adobe Acrobat Reader*' -or $_.DisplayName -like '*Acrobat Reader*' }
        if ($items) { return 'AcroExch.Document.DC' } # sensible default for modern Reader
    }

    return $null
}

function Test-ReaderInstalled {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($path in $paths) {
        $hit = Get-ItemProperty -Path ($path + '\*') -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Adobe Acrobat Reader*' -or $_.DisplayName -like '*Acrobat Reader*' }
        if ($hit) { return $true }
    }
    return $false
}

# 1) Confirm Reader is installed
$readerInstalled = Test-ReaderInstalled
if (-not $readerInstalled) {
    Write-Output "Adobe Acrobat Reader not found. Install Reader first, then re-run."
    exit 1
}

# 2) Resolve Reader ProgID
$progId = Get-AcrobatReaderProgId
if (-not $progId) {
    # Default to Reader DC ProgID if detection failed
    $progId = 'AcroExch.Document.DC'
    Write-Output "Could not verify ProgID in HKCR. Defaulting to $progId."
}

# 3) Create Default App Associations XML
$xmlPath = 'C:\ProgramData\DefaultPDF_Associations.xml'
$xmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
    <Association Identifier=".pdf" ProgId="$progId" ApplicationName="Adobe Acrobat Reader"/>
</DefaultAssociations>
"@

# Ensure folder exists and write the XML
$newDir = Split-Path $xmlPath -Parent
if (-not (Test-Path $newDir)) { New-Item -ItemType Directory -Path $newDir | Out-Null }
$xmlContent | Out-File -FilePath $xmlPath -Encoding ascii -Force

# 4) Import associations (system-wide)
$import = Start-Process -FilePath 'dism.exe' -ArgumentList "/Online /Import-DefaultAppAssociations:$xmlPath" -Wait -PassThru
if ($import.ExitCode -ne 0) {
    Write-Output "DISM import failed with exit code $($import.ExitCode)."
    exit $import.ExitCode
}

Write-Output "Imported default app associations successfully. PDF -> $progId (Adobe Reader)."

# 5) Optional: refresh per-user defaults (applies at next logon; Windows may delay)
# You can log off users or schedule a reboot. Here we just print guidance.
Write-Output "Note: Windows may apply the new default at next user logon or reboot."
