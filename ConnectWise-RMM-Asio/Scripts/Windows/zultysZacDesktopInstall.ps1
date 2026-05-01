[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [Alias("MsiUrl")]
    [ValidateNotNullOrEmpty()]
    [string]$InstallerUrl = "https://mirror.zultys.biz/ZAC/",

    [Parameter(Mandatory = $false)]
    [string]$MxServer = "@mx_server_url@",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ShortcutName = "Zultys ZAC"
)


# Validate MX server parameter (RMM token replacement check)
if ([string]::IsNullOrWhiteSpace($MxServer) -or $MxServer -eq "@mx_server_url@") {
    Write-Output "ERROR: MX server URL was not provided. Ensure the RMM parameter @mx_server_url@ is set."
    Write-Output "NONCOMPLIANT"
    exit 1
}

# Normalize MX server input (strip protocol and trailing slash)
$MxServer = $MxServer -replace '^https?://', ''
$MxServer = $MxServer.TrimEnd('/')

# Basic validation to ensure it still looks like a hostname
if ($MxServer -notmatch '^[a-zA-Z0-9.-]+$') {
    Write-Output "ERROR: MX server value '$MxServer' is not a valid hostname."
    Write-Output "NONCOMPLIANT"
    exit 1
}

$ErrorActionPreference = "Stop"

$WorkDir = Join-Path $env:TEMP "ZultysZAC"
$ResolvedInstallerUrl = $null
$InstallerPath = $null
$InstallLogPath = Join-Path $WorkDir "ZultysZAC_Install.log"
$ShortcutPath = Join-Path $env:PUBLIC "Desktop\$ShortcutName.lnk"

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    # Use Write-Host so status messages do not pollute function return values.
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Get-ZacExecutablePath {
    $candidatePaths = @(
        "C:\Program Files\Zultys\ZAC\Bin\zac.exe",
        "C:\Program Files\Zultys\ZAC\zac.exe",
        "C:\Program Files (x86)\Zultys\ZAC\Bin\zac.exe",
        "C:\Program Files (x86)\Zultys\ZAC\zac.exe"
    )

    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    $searchRoots = @(
        "C:\Program Files\Zultys",
        "C:\Program Files (x86)\Zultys"
    )

    foreach ($root in $searchRoots) {
        if (Test-Path -LiteralPath $root) {
            $found = Get-ChildItem -LiteralPath $root -Filter "zac.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                return $found.FullName
            }
        }
    }

    return $null
}

function Resolve-ZacInstallerUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $Uri = [string]$Uri
    $Uri = $Uri.Trim()
    # Direct installer file provided
    if ($Uri -match "(?i)\.(exe|msi)$") {
        return $Uri
    }

    # Zultys public landing page is not a direct or browsable installer source.
    if ($Uri -match "zultys.com/zac-download") {
        throw "The Zultys public download URL is not a direct installer file. Use the Zultys mirror folder URL or a direct .exe/.msi URL."
    }

    Write-Status "Installer URL appears to be a folder/listing. Resolving latest ZAC x64 installer from $Uri"

    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing
    }
    catch {
        throw "Failed to read installer listing at $Uri. Error: $($_.Exception.Message)"
    }

    $links = New-Object System.Collections.Generic.List[string]

    if ($response.Links) {
        foreach ($link in $response.Links) {
            if ($link.href) {
                [void]$links.Add([string]$link.href)
            }
        }
    }

    # Fallback for basic directory listings where Links parsing is unavailable or incomplete.
    foreach ($match in [regex]::Matches($response.Content, 'href=["'']([^"'']+)["'']')) {
        if ($match.Groups[1].Value) {
            [void]$links.Add([string]$match.Groups[1].Value)
        }
    }

    $installerCandidates = $links |
        Select-Object -Unique |
        Where-Object { $_ -match '(?i)^ZAC_x64-(\d+(?:\.\d+){1,4})\.exe$' } |
        ForEach-Object {
            $href = [string]$_
            $fileName = [System.IO.Path]::GetFileName($href)
            $versionText = [regex]::Match($fileName, '(\d+(?:\.\d+){1,4})').Value

            [pscustomobject]@{
                FileName = $fileName
                Version  = [version]$versionText
                Href     = $href
            }
        } |
        Sort-Object -Property Version -Descending

    $latest = $installerCandidates | Select-Object -First 1

    if (-not $latest) {
        throw "No ZAC_x64-*.exe installers were found at $Uri"
    }

    $baseUrl = [string]$Uri
    if (-not $baseUrl.EndsWith('/')) {
        $baseUrl = "$baseUrl/"
    }

    $href = [string]$latest.Href
    $href = $href.TrimStart('/')
    $resolvedUri = "$baseUrl$href"

    Write-Status "Latest ZAC installer resolved: $($latest.FileName) / version $($latest.Version)"
    return $resolvedUri
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Write-Status "Downloading ZAC installer from $Uri"

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    }
    catch {
        Write-Status "Invoke-WebRequest failed. Attempting BITS download. Error: $($_.Exception.Message)"
        Start-BitsTransfer -Source $Uri -Destination $Destination
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Installer download failed. File was not created at $Destination"
    }

    $downloadedFile = Get-Item -LiteralPath $Destination
    if ($downloadedFile.Length -le 0) {
        throw "Installer download failed. Downloaded file is empty: $Destination"
    }

    Write-Status "Downloaded installer to $Destination ($([Math]::Round($downloadedFile.Length / 1MB, 2)) MB)"
}

function Install-ZacInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    switch ($extension) {
        ".msi" {
            Write-Status "Installing ZAC MSI silently"

            $arguments = @(
                "/i"
                "`"$Path`""
                "/qn"
                "/norestart"
                "/l*v"
                "`"$LogPath`""
            ) -join " "

            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
        }
        ".exe" {
            Write-Status "Installing ZAC EXE silently"

            # ZAC mirror installers are EXE files. /S is the common silent switch for this installer style.
            # If Zultys changes installer packaging, update this argument to the vendor-supported silent switch.
            $arguments = "/S"
            $process = Start-Process -FilePath $Path -ArgumentList $arguments -Wait -PassThru
        }
        default {
            throw "Unsupported installer extension '$extension'. Provide a direct .exe or .msi installer URL."
        }
    }

    switch ($process.ExitCode) {
        0 { Write-Status "ZAC installer completed successfully." }
        3010 { Write-Status "ZAC installer completed successfully. Reboot required." }
        default { throw "ZAC installer failed with exit code $($process.ExitCode). Review log if available: $LogPath" }
    }
}

function New-ZacShortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Write-Status "Creating shortcut: $Path"

    $shortcutDirectory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $shortcutDirectory)) {
        New-Item -Path $shortcutDirectory -ItemType Directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = "u=$Server"
    $shortcut.WorkingDirectory = Split-Path -Path $TargetPath -Parent
    $shortcut.IconLocation = "$TargetPath,0"
    $shortcut.Save()

    Write-Status "Shortcut created with arguments: u=$Server"
}

try {
    Write-Status "Starting Zultys ZAC Desktop installation task."

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    }

    $ResolvedInstallerUrl = Resolve-ZacInstallerUrl -Uri $InstallerUrl
    $ResolvedInstallerUrl = [string]$ResolvedInstallerUrl
    Write-Status "Resolved installer URL: $ResolvedInstallerUrl"

    $InstallerExtension = [System.IO.Path]::GetExtension(([string]$ResolvedInstallerUrl).Split('?')[0])
    if ([string]::IsNullOrWhiteSpace($InstallerExtension)) {
        throw "Unable to determine installer file extension from resolved URL: $ResolvedInstallerUrl"
    }
    $InstallerPath = Join-Path $WorkDir "ZultysZAC$InstallerExtension"

    Invoke-FileDownload -Uri $ResolvedInstallerUrl -Destination $InstallerPath
    Install-ZacInstaller -Path $InstallerPath -LogPath $InstallLogPath

    $zacExePath = Get-ZacExecutablePath
    if (-not $zacExePath) {
        throw "ZAC executable was not found after installation. Review installer output and log if available: $InstallLogPath"
    }

    Write-Status "Found ZAC executable: $zacExePath"

    New-ZacShortcut -TargetPath $zacExePath -Server $MxServer -Path $ShortcutPath

    Write-Status "Zultys ZAC Desktop deployment completed successfully."
    Write-Output "COMPLIANT"
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output "NONCOMPLIANT"
    exit 1
}