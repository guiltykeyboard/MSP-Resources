<#
.SYNOPSIS
    Installs the DNSFilter Windows agent from ConnectWise RMM, picking the x64 or
    ARM64 MSI from the endpoint's real OS architecture and reading the site secret
    key from a site-level custom field.

.DESCRIPTION
    Built to run as SYSTEM from a ConnectWise RMM (Asio) task with no interactive
    input and nothing left behind on the endpoint.

    ARCHITECTURE
      PROCESSOR_ARCHITECTURE alone is not trustworthy: a 32-bit PowerShell host on
      ARM64 reports 'x86' and you would push the x64 MSI at an ARM box. The script
      checks PROCESSOR_ARCHITEW6432, then RuntimeInformation.OSArchitecture, then
      Win32_Processor.Architecture (12 = ARM64, 9 = x64) before choosing a package,
      and refuses a 32-bit-only OS instead of guessing.

    SITE TOKEN
      -SiteToken defaults to the literal @DNSFilter-Site-Token@, which RMM replaces
      from the site-level custom field of that name. If the placeholder arrives
      unsubstituted - field empty, or no mapping on the task - the script stops with
      exit 2 rather than installing an agent that silently binds to nothing. The key
      is never written to the log; only a masked hint is.

    STAGING
      The MSI is downloaded to a GUID subfolder of $env:TEMP, installed from there,
      and that folder is deleted in a finally block, so neither installer nor
      msiexec log survives. The msiexec log is copied to %ProgramData%\iTech\Logs
      first so a failure is still diagnosable after cleanup.

    IDEMPOTENCY
      An existing agent (modern 'DNSFilter Agent' or legacy whitelabel 'DNS Agent')
      is detected in both registry views and left alone. -Force repairs or re-keys
      it, -Uninstall removes it by its Add/Remove Programs product code, -TestOnly
      reports the plan and changes nothing.

    SAFETY
      -TestOnly is evaluated before any mutating path, so '-Uninstall -TestOnly' is
      a pre-flight that removes nothing. Reporting and the exit code are emitted at
      a single exit point that every completion path reaches, so RMM never reads a
      failed run as green.

    OUTPUT
      One-line JSON on STDOUT for RMM parsing.
      Exit 0 = installed or already present, 1 = install/verify failed,
      2 = parameter or prerequisite problem.

.PARAMETER SiteToken
    Site secret key for this client. The default @DNSFilter-Site-Token@ is replaced
    by RMM from the site-level custom field of the same name. Falls back to
    $env:DNSFilter_Site_Token when empty.

.PARAMETER Architecture
    Auto (default), x64 or arm64. Auto uses real OS detection; override to force.

.PARAMETER AgentVersion
    Pin a build, e.g. 3.6.10, requesting DNSFilter-Agent-Setup-<arch>-3.6.10.msi.
    Empty (default) uses the evergreen unversioned package.

.PARAMETER BaseUrl
    Download root. Default https://downloads.dnsfilter.com/User_Agent/Windows

.PARAMETER Force
    Reinstall or repair an existing agent with the supplied key
    (REINSTALL=ALL REINSTALLMODE=vomus).

.PARAMETER Uninstall
    Remove the agent by product code and exit. No token required.
    With -TestOnly it reports what would be removed and removes nothing.

.PARAMETER TestOnly
    Report resolved architecture, package URL, token state and installed product.
    Downloads, installs and uninstalls nothing. Evaluated before every mutating
    path.

.PARAMETER ProbeLocalResolver
    After a successful install, resolve dnsfilter.com against 127.0.0.1 and record
    the answer. Informational only; never changes the exit code.

.PARAMETER LogPath
    Transcript log. Default %ProgramData%\iTech\Logs\DNSFilter-Agent-<host>.log

.PARAMETER DownloadRetries
    Download attempts before giving up. Default 3.

.EXAMPLE
    # RMM payload: architecture and site key both come from the task/site field
    .\Deploy-DNSFilterAgent.ps1

.EXAMPLE
    # Pilot on one endpoint, pinned build, change nothing
    .\Deploy-DNSFilterAgent.ps1 -SiteToken 'yoursitekey' -AgentVersion '3.6.10' -TestOnly

.EXAMPLE
    # Re-key an agent that was installed with the wrong site key
    .\Deploy-DNSFilterAgent.ps1 -SiteToken 'yoursitekey' -Force

.EXAMPLE
    # Remove the agent (detects modern and legacy whitelabel builds)
    .\Deploy-DNSFilterAgent.ps1 -Uninstall

.EXAMPLE
    # Pre-flight an uninstall: reports what would be removed, changes nothing
    .\Deploy-DNSFilterAgent.ps1 -Uninstall -TestOnly

.NOTES
    Target: Windows 10/11 and Server 2016+ on x64 and ARM64. Windows Installer
    handles the ARM64 MSI natively on Windows 11 ARM64.
    Site keys are alphanumeric; anything with quotes, spaces or backslashes is
    rejected before it reaches a command line.
    Add/Remove Programs is read through both registry views explicitly, so a 32-bit
    PowerShell host still sees a native x64 or ARM64 agent.
    Exit codes: 0 = ok, 1 = install failed, 2 = parameter/prerequisite problem.

.LINK
    https://help.dnsfilter.com/hc/en-us/articles/1500008104822-Windows-Roaming-Client-Deployment-Guide
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SiteToken = '@DNSFilter-Site-Token@',

    [ValidateSet('Auto', 'x64', 'arm64')]
    [string]$Architecture = 'Auto',

    [ValidatePattern('^$|^\d+(\.\d+){1,3}$')]
    [string]$AgentVersion = '',

    [string]$BaseUrl = 'https://downloads.dnsfilter.com/User_Agent/Windows',

    [switch]$Force,
    [switch]$Uninstall,
    [switch]$TestOnly,
    [switch]$ProbeLocalResolver,

    [string]$LogPath = "$env:ProgramData\iTech\Logs\DNSFilter-Agent-$env:COMPUTERNAME.log",

    [ValidateRange(1, 10)]
    [int]$DownloadRetries = 3
)

# Baked commit fallback (replaced by CI)
$Script:GIT_COMMIT = '@GIT_COMMIT@'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:ExitCode = 0
$script:WorkDir  = $null

$commitDisplay = 'unstamped'
if ($Script:GIT_COMMIT -and $Script:GIT_COMMIT -notmatch '^@') { $commitDisplay = $Script:GIT_COMMIT }

$script:Result = [ordered]@{
    script       = 'Deploy-DNSFilterAgent'
    commit       = $commitDisplay
    computer     = $env:COMPUTERNAME
    when         = (Get-Date).ToString('o')
    action       = 'none'
    architecture = $null
    package      = $null
    tokenState   = $null
    status       = 'not-started'
    msiExit      = $null
    product      = $null
    version      = $null
    service      = $null
    resolverProbe = $null
    exitCode     = 0
    detail       = $null
}

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '{0} [{1}] {2}' -f $stamp, $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red;    $script:ExitCode = 1 }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Get-MaskedToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '(empty)' }
    if ($Value.Length -le 6) { return '******' }
    return ('{0}...{1}' -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 2))
}

function Get-OsArchitecture {
    # Return 'arm64', 'x64' or $null when the OS is 32-bit only.
    # 1) Env vars: ARCHITEW6432 shows the real OS arch for a 32-bit host process.
    if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'arm64' }
    # 2) .NET 4.7.1+ / PowerShell 7 reports the OS architecture directly.
    try {
        $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        if ($osArch -match 'Arm64') { return 'arm64' }
        if ($osArch -match 'X64')   { return 'x64' }
        if ($osArch -match 'X86')   { return $null }
    } catch { }
    # 3) WMI: Win32_Processor.Architecture 12 = ARM64, 9 = x64, 0 = x86.
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu) {
            switch ([int]$cpu.Architecture) {
                12 { return 'arm64' }
                9  { return 'x64' }
                0  { return $null }
            }
        }
    } catch { }
    # 4) Last resort: WOW64 presence means a 64-bit OS, and no ARM signal was seen.
    if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { return 'x64' }
    return $null
}

function Get-UninstallEntries {
    # Read one registry view explicitly. A 32-bit PowerShell host is redirected for
    # HKLM:\SOFTWARE, so the provider path alone would hide a native agent; opening
    # the views by name is the only reliable way to see both.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Registry64', 'Registry32')]
        [string]$View
    )
    $subKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $base   = $null
    $root   = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
        $root = $base.OpenSubKey($subKey)
        if (-not $root) { return @() }
        $found = @()
        foreach ($name in $root.GetSubKeyNames()) {
            $child = $null
            try {
                $child = $root.OpenSubKey($name)
                if (-not $child) { continue }
                $display = $child.GetValue('DisplayName')
                if (-not $display) { continue }
                $found += [pscustomobject]@{
                    Name        = [string]$display
                    Version     = [string]$child.GetValue('DisplayVersion')
                    Publisher   = [string]$child.GetValue('Publisher')
                    ProductCode = $name
                    View        = $View
                }
            } catch {
                continue
            } finally {
                if ($child) { $child.Dispose() }
            }
        }
        return $found
    } catch {
        # View unavailable (a 32-bit OS has no Registry64) - nothing to report.
        return @()
    } finally {
        if ($root) { $root.Dispose() }
        if ($base) { $base.Dispose() }
    }
}

function Get-InstalledAgent {
    # Scan Add/Remove Programs, both registry views, for the modern or legacy agent.
    foreach ($view in @('Registry64', 'Registry32')) {
        foreach ($entry in (Get-UninstallEntries -View $view)) {
            if ($entry.Name -notmatch 'DNSFilter|DNS\s*Agent') { continue }
            # Exclude unrelated "DNS Agent" products by requiring the vendor name.
            if ($entry.Name -notmatch 'DNSFilter' -and $entry.Publisher -notmatch 'DNSFilter') { continue }
            return [pscustomobject]@{
                Name        = $entry.Name
                Version     = $entry.Version
                ProductCode = $entry.ProductCode
                View        = $entry.View
            }
        }
    }
    return $null
}

function Get-AgentService {
    # Service names differ between builds ('DNSFilter Agent' / legacy 'DNS Agent'),
    # so match on the binary path rather than guessing a name.
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.PathName -match 'DNSFilter|DNS\s*Agent' } |
            Select-Object -First 1
        if ($svc) { return ('{0} ({1})' -f $svc.Name, $svc.State) }
    } catch { }
    return $null
}

function Save-AgentPackage {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Retries
    )
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
            $sw.Stop()
            $size = (Get-Item -LiteralPath $Destination).Length
            $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            Write-Log -Level OK -Message ('Downloaded {0} bytes in {1:n0} ms  sha256={2}' -f $size, $sw.Elapsed.TotalMilliseconds, $hash)
            return
        } catch {
            if ($attempt -eq $Retries) { throw }
            $wait = [Math]::Min(30, 5 * $attempt)
            Write-Log -Level WARN -Message ('Download attempt {0}/{1} failed ({2}). Retrying in {3}s.' -f $attempt, $Retries, $_.Exception.Message, $wait)
            Start-Sleep -Seconds $wait
        }
    }
}

function Test-MsiPackage {
    # An HTML error page saved as .msi is a classic CDN/proxy failure; check the
    # OLE compound-file signature before handing the file to Windows Installer.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 102400) { return $false }
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $sig = New-Object byte[] 8
        if ($fs.Read($sig, 0, 8) -lt 8) { return $false }
        $hex = ($sig | ForEach-Object { $_.ToString('X2') }) -join ''
        return ($hex -eq 'D0CF11E0A1B11AE1')
    } catch {
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Invoke-Msi {
    param([Parameter(Mandatory)][string]$Arguments)
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    return [int]$proc.ExitCode
}

function Get-MsiOutcome {
    param([Parameter(Mandatory)][int]$Code)
    switch ($Code) {
        0    { return [pscustomobject]@{ Ok = $true;  Status = 'installed';          Note = 'Success' } }
        3010 { return [pscustomobject]@{ Ok = $true;  Status = 'installed-reboot';   Note = 'Success, reboot required' } }
        1641 { return [pscustomobject]@{ Ok = $true;  Status = 'installed-reboot';   Note = 'Success, restart initiated' } }
        1603 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1603 fatal error during installation; read the msiexec log (often an existing install or a policy block)' } }
        1618 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1618 another installation is in progress; retry later' } }
        1619 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1619 package could not be opened; the download is corrupt' } }
        1620 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1620 package could not be accessed; check file permissions and AV' } }
        1625 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1625 installation forbidden by policy; check AppLocker or Software Restriction Policies' } }
        1633 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1633 package is not supported on this platform; architecture mismatch' } }
        1638 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1638 another version is already installed; use -Force to repair or re-key' } }
        1639 { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = '1639 invalid command line argument' } }
        default { return [pscustomobject]@{ Ok = $false; Status = 'failed'; Note = ('msiexec returned {0}' -f $Code) } }
    }
}

function New-StagingDirectory {
    $tempRoot = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = $env:TMP }
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = [System.IO.Path]::GetTempPath() }
    $dir = Join-Path -Path $tempRoot -ChildPath ('DNSFilterAgent_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# --------------------------------------------------------------------------
# Main workflow
# --------------------------------------------------------------------------
function Invoke-Deployment {
    Write-Log -Level INFO -Message ('=== Deploy-DNSFilterAgent {0} on {1} ({2}/{3}) ===' -f $commitDisplay, $env:COMPUTERNAME, $env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432)

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Log -Level ERROR -Message 'This is a 32-bit-only Windows installation; DNSFilter publishes x64 and ARM64 agents only.'
        $script:Result.status = 'unsupported-os'
        $script:Result.detail = '32-bit-only OS'
        $script:ExitCode = 2
        throw [System.OperationCanceledException]::new('unsupported-os')
    }

    # ---- architecture ----
    $detected = $null
    if ($Architecture -eq 'Auto') {
        $detected = Get-OsArchitecture
        if (-not $detected) {
            Write-Log -Level ERROR -Message 'Could not determine whether this endpoint is x64 or ARM64. Pass -Architecture x64 or -Architecture arm64 explicitly.'
            $script:Result.status = 'architecture-unknown'
            $script:ExitCode = 2
            throw [System.OperationCanceledException]::new('architecture-unknown')
        }
        $Architecture = $detected
    }
    $script:Result.architecture = $Architecture
    Write-Log -Message ('Architecture: {0} (detected {1})' -f $Architecture, $detected)

    # ---- site token ----
    $tokenState = 'parameter'
    if ($Uninstall) {
        # Uninstall never needs the key, so a pre-flight of it must not demand one.
        $tokenState = 'not-required'
    } else {
        if ([string]::IsNullOrWhiteSpace($SiteToken) -or $SiteToken -match '^@[^@]+@$') {
            if (-not [string]::IsNullOrWhiteSpace($env:DNSFilter_Site_Token)) {
                $SiteToken = $env:DNSFilter_Site_Token
                $tokenState = 'environment'
            } else {
                $tokenState = 'missing'
            }
        }
        if ($tokenState -eq 'missing') {
            Write-Log -Level ERROR -Message '-SiteToken was not substituted by RMM. Check that the site has a custom field named DNSFilter-Site-Token and that the task maps it; the agent will not bind to a site without a key.'
            $script:Result.status = 'missing-token'
            $script:Result.tokenState = 'missing'
            $script:ExitCode = 2
            throw [System.OperationCanceledException]::new('missing-token')
        }
        if ($SiteToken -notmatch '^[A-Za-z0-9][A-Za-z0-9._\-]{5,199}$') {
            Write-Log -Level ERROR -Message 'The site key contains unexpected characters (quotes, spaces, slashes). Copy it again from DNSFilter > Sites.'
            $script:Result.status = 'invalid-token'
            $script:Result.tokenState = 'invalid'
            $script:ExitCode = 2
            throw [System.OperationCanceledException]::new('invalid-token')
        }
        Write-Log -Message ('Site token ({0}): {1}' -f $tokenState, (Get-MaskedToken $SiteToken))
    }
    $script:Result.tokenState = $tokenState

    # ---- package url ----
    $versionSuffix = ''
    if ($AgentVersion) { $versionSuffix = '-' + $AgentVersion }
    $packageUrl = '{0}/DNSFilter-Agent-Setup-{1}{2}.msi' -f $BaseUrl.TrimEnd('/'), $Architecture, $versionSuffix
    $script:Result.package = $packageUrl

    # ---- current state ----
    $installed = Get-InstalledAgent
    $service   = Get-AgentService
    if ($installed) {
        Write-Log -Message ('Existing agent: {0} {1} (product code {2}, {3})' -f $installed.Name, $installed.Version, $installed.ProductCode, $installed.View)
        $script:Result.product = $installed.Name
        $script:Result.version = $installed.Version
    } else {
        Write-Log -Message 'No existing DNSFilter agent found in Add/Remove Programs (both registry views).'
    }
    if ($service) {
        Write-Log -Message ('Agent service: {0}' -f $service)
        $script:Result.service = $service
    }

    # ---- pre-flight: evaluated BEFORE any mutating path ----
    if ($TestOnly) {
        $script:Result.action = 'preflight'
        $script:Result.status = 'preflight-ok'
        $script:ExitCode = 0
        if ($Uninstall) {
            if ($installed) {
                Write-Log -Level OK -Message ('Pre-flight only. Would uninstall {0} {1} (product code {2}). Nothing was changed.' -f $installed.Name, $installed.Version, $installed.ProductCode)
            } else {
                Write-Log -Level OK -Message 'Pre-flight only. No agent is installed, so an uninstall run would report nothing to remove. Nothing was changed.'
            }
            return
        }
        Write-Log -Level OK -Message ('Pre-flight only. Would install {0}. Nothing was changed.' -f $packageUrl)
        if ($installed -and -not $Force) { Write-Log -Message 'An agent is already present; a real run would exit 0 without reinstalling.' }
        if ($installed -and $Force) { Write-Log -Message 'An agent is present and -Force is set; a real run would repair it with the supplied key.' }
        return
    }

    # ---- uninstall path ----
    if ($Uninstall) {
        if (-not $installed) {
            Write-Log -Level OK -Message 'Nothing to remove; no DNSFilter agent is installed.'
            $script:Result.action = 'uninstall'
            $script:Result.status = 'not-installed'
            $script:ExitCode = 0
            return
        }
        $script:WorkDir = New-StagingDirectory
        $uninstallLog  = Join-Path $script:WorkDir 'msiexec.log'
        $uninstallArgs = '/x "{0}" /qn /norestart /l*v "{1}"' -f $installed.ProductCode, $uninstallLog
        Write-Log -Message ('Uninstalling {0} {1}' -f $installed.Name, $installed.Version)
        $code    = Invoke-Msi -Arguments $uninstallArgs
        $outcome = Get-MsiOutcome -Code $code
        $script:Result.action  = 'uninstall'
        $script:Result.msiExit = $code
        $script:Result.status  = if ($outcome.Ok) { 'uninstalled' } else { 'uninstall-failed' }
        $script:Result.detail  = $outcome.Note
        if ($outcome.Ok) {
            Write-Log -Level OK -Message ('Uninstall complete: {0}' -f $outcome.Note)
            $script:ExitCode = 0
        } else {
            Write-Log -Level ERROR -Message ('Uninstall failed: {0}' -f $outcome.Note)
            $script:ExitCode = 1
        }
        return
    }

    # ---- already installed ----
    if ($installed -and -not $Force) {
        Write-Log -Level OK -Message ('DNSFilter agent already installed ({0} {1}); nothing to do. Use -Force to repair or re-key.' -f $installed.Name, $installed.Version)
        $script:Result.action = 'skip'
        $script:Result.status = 'already-installed'
        $script:ExitCode = 0
        return
    }

    # ---- download ----
    $script:WorkDir = New-StagingDirectory
    $msiName = 'DNSFilter-Agent-Setup-{0}{1}.msi' -f $Architecture, $versionSuffix
    $msiPath = Join-Path $script:WorkDir $msiName
    Write-Log -Message ('Staging in {0}' -f $script:WorkDir)
    Write-Log -Message ('Downloading {0}' -f $packageUrl)
    try {
        Save-AgentPackage -Url $packageUrl -Destination $msiPath -Retries $DownloadRetries
    } catch {
        Write-Log -Level ERROR -Message ('Download failed after {0} attempts: {1}' -f $DownloadRetries, $_.Exception.Message)
        $script:Result.status = 'download-failed'
        $script:Result.detail = $_.Exception.Message
        $script:ExitCode = 2
        throw [System.OperationCanceledException]::new('download-failed')
    }
    if (-not (Test-MsiPackage -Path $msiPath)) {
        Write-Log -Level ERROR -Message 'The downloaded file is not a valid MSI (bad signature or truncated). A proxy or content filter may be intercepting downloads.dnsfilter.com.'
        $script:Result.status = 'invalid-package'
        $script:Result.detail = 'MSI signature check failed'
        $script:ExitCode = 2
        throw [System.OperationCanceledException]::new('invalid-package')
    }

    # ---- install ----
    $msiLog      = Join-Path $script:WorkDir 'msiexec.log'
    $installArgs = '/i "{0}" /qn /norestart /l*v "{1}" NKEY="{2}"' -f $msiPath, $msiLog, $SiteToken
    if ($installed -and $Force) { $installArgs = $installArgs + ' REINSTALL=ALL REINSTALLMODE=vomus' }
    $action = if ($installed) { 'repair' } else { 'install' }
    Write-Log -Message ('Running msiexec {0} (action: {1})' -f $msiName, $action)
    $code    = Invoke-Msi -Arguments $installArgs
    $outcome = Get-MsiOutcome -Code $code
    $script:Result.action  = $action
    $script:Result.msiExit = $code
    $script:Result.detail  = $outcome.Note
    if (-not $outcome.Ok) {
        Write-Log -Level ERROR -Message ('Install failed: {0}' -f $outcome.Note)
        $script:Result.status = $outcome.Status
        $script:ExitCode = 1
        return
    }
    Write-Log -Level OK -Message ('msiexec: {0}' -f $outcome.Note)

    # ---- verify ----
    $after   = Get-InstalledAgent
    $service = Get-AgentService
    if ($after) {
        $script:Result.product = $after.Name
        $script:Result.version = $after.Version
    }
    if ($service) { $script:Result.service = $service }

    if (-not $after -and -not $service) {
        Write-Log -Level ERROR -Message 'msiexec reported success but no DNSFilter product or service is present. The install did not take; re-run with the msiexec log from the logs folder.'
        $script:Result.status = 'installed-unverified'
        $script:ExitCode = 1
        return
    }
    Write-Log -Level OK -Message ('Verified: {0} {1}; service {2}' -f $after.Name, $after.Version, $service)
    $script:Result.status = $outcome.Status
    $script:ExitCode = 0

    # ---- optional resolver probe ----
    if ($ProbeLocalResolver) {
        try {
            $answer = Resolve-DnsName -Name 'dnsfilter.com' -Server '127.0.0.1' -DnsOnly -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
            if ($answer) {
                $script:Result.resolverProbe = 'resolved:' + $answer.IPAddress
                Write-Log -Message ('Local resolver probe: dnsfilter.com -> {0}' -f $answer.IPAddress)
            } else {
                $script:Result.resolverProbe = 'no-answer'
                Write-Log -Level WARN -Message 'Local resolver probe returned no A record.'
            }
        } catch {
            $script:Result.resolverProbe = 'error:' + $_.Exception.Message
            Write-Log -Level WARN -Message ('Local resolver probe failed: {0}' -f $_.Exception.Message)
        }
    }
}

try {
    Invoke-Deployment
}
catch [System.OperationCanceledException] {
    # Already logged and coded by the branch that aborted.
}
catch {
    Write-Log -Level ERROR -Message ('Unhandled failure: {0}' -f $_.Exception.Message)
    $script:Result.status = 'error'
    $script:Result.detail = $_.Exception.Message
    $script:ExitCode = 1
}
finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        $msiLogPath = Join-Path $script:WorkDir 'msiexec.log'
        if (Test-Path -LiteralPath $msiLogPath) {
            try {
                $logDir = Split-Path -Parent $LogPath
                if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                $keepLog = Join-Path $logDir ('DNSFilter-msiexec-{0}.log' -f $env:COMPUTERNAME)
                Copy-Item -LiteralPath $msiLogPath -Destination $keepLog -Force -ErrorAction Stop
                Write-Log -Message ('msiexec log kept at {0}' -f $keepLog)
            } catch {
                Write-Log -Level WARN -Message ('Could not preserve the msiexec log: {0}' -f $_.Exception.Message)
            }
        }
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:WorkDir) {
            Write-Log -Level WARN -Message ('Staging folder still present: {0}' -f $script:WorkDir)
        } else {
            Write-Log -Message ('Staging folder removed: {0}' -f $script:WorkDir)
        }
    }
}

# Single exit point: every completion path reaches this, so the JSON summary is
# always emitted and the exit code is always propagated.
$script:Result.exitCode = $script:ExitCode
$script:Result | ConvertTo-Json -Compress -Depth 4
exit $script:ExitCode
