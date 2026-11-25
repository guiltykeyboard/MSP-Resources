<#
.SYNOPSIS
    Removes the DNSFilter Windows agent (standard or legacy whitelabel) from
    ConnectWise RMM when the dashboard uninstall did not work.

.DESCRIPTION
    The dashboard can uninstall the agent from v2.0.1 onwards. For anything older,
    and for agents that are stuck, offline, or already deleted from the dashboard,
    the agent stays on the endpoint and this script is the cleanup path.

    VERSION MATTERS
      v2.0.1 and newer  msiexec /X{code} honours the REGCLEAN property, so the
                        uninstall can also clear the agent's registry state.
      v1.15.3 and older REGCLEAN is not part of that path. The MSI removes the
                        product; this script then clears the residue the old
                        installer leaves behind.

    FINDING AN AGENT
      Add/Remove Programs is not enough. Older builds were often installed with
      ARPSYSTEMCOMPONENT=1, which hides the agent from that list while it keeps
      running. Detection therefore unions four sources:
        1. Add/Remove Programs, both registry views
        2. HKLM\SOFTWARE\DNSFilter\Agent and HKLM\SOFTWARE\DNSAgent\Agent
        3. the Windows Installer product database through its COM API, which
           still lists a product hidden from Add/Remove Programs
        4. the agent service and install directory, in every programs root
      Win32_Product is deliberately not used: querying it makes Windows Installer
      run a consistency check against every installed product.

    REMOVAL
      Each agent is removed with msiexec /X by product code. The verbose MSI log
      (/l*vx!) is written to a temporary file, then a digest is echoed to STDOUT so
      it lands in the RMM script output - no local log file needed to see why a
      removal failed. The full log is also kept under %ProgramData%\iTech\Logs.

    DNS
      The agent points adapters at 127.0.0.1. If a removal leaves that behind, the
      endpoint has no working DNS. -DnsCleanup Clean (default) strips loopback
      servers from active adapters and falls back to DHCP when nothing else
      remains; Report only lists them. A DNS pass that cannot inspect an adapter is
      a failure, not a silent skip: an uninspected endpoint is not a clean one.

    OUTPUT
      One-line JSON on STDOUT plus an MSI log digest.
      Exit 0 = nothing installed or everything removed, 1 = a removal failed or
      residue remains, 2 = parameter or prerequisite problem.

.PARAMETER RegClean
    Auto (default) passes REGCLEAN=true only for agents at v2.0.1 or newer. True
    forces it, False disables it and preserves the agent's configuration keys and
    ProgramData folder.

.PARAMETER ForceCleanup
    Also remove residue (service, directories, registry keys) after a FAILED
    msiexec. By default residue is only cleaned when the uninstall reported
    success, so a failed MSI does not get its evidence deleted.

.PARAMETER DnsCleanup
    Clean (default) or Report. Controls whether loopback DNS servers are stripped
    from adapters after removal.

.PARAMETER TestOnly
    Report every agent found, where it was found, its version and the recipe that
    would be used. Changes nothing.

.PARAMETER FullMsiLog
    Echo the whole msiexec log instead of the digest. Noisy; use when support asks
    for it.

.PARAMETER LogTailLines
    Lines of msiexec log tail included in the digest. Default 40.

.PARAMETER LogPath
    Transcript log. Default %ProgramData%\iTech\Logs\DNSFilter-Uninstall-<host>.log

.EXAMPLE
    # Standard RMM task: remove whatever agent is present, both kinds, clean DNS
    .\Uninstall-DNSFilterAgent.ps1

.EXAMPLE
    # See what would happen without touching anything
    .\Uninstall-DNSFilterAgent.ps1 -TestOnly

.EXAMPLE
    # Keep the agent's registry config for a re-key
    .\Uninstall-DNSFilterAgent.ps1 -RegClean:$false

.EXAMPLE
    # Stuck agent: force the cleanup even if msiexec fails
    .\Uninstall-DNSFilterAgent.ps1 -ForceCleanup -FullMsiLog

.NOTES
    Run as SYSTEM. Removes both the modern 'DNSFilter Agent' and the legacy
    whitelabel 'DNS Agent', so a machine carrying both ends up clean.
    Residue cleanup is deferred until every removal attempt has finished and is
    scoped to the products that were actually removed, so one product's success
    cannot delete another product's files first.
    Verification asks Add/Remove Programs and the MSI database, never the agent's own
    configuration key, so a preserved config GUID is not mistaken for an install.
    A registry key or adapter that could not be inspected is recorded as residue;
    a run never reports success for something it failed to look at.
    HKCU tray-icon residue belongs to the logged-on user profile, not SYSTEM, so it
    is reported rather than silently rewritten.
    Exit codes: 0 = ok, 1 = failed/residue, 2 = parameter/prerequisite problem.

.LINK
    https://help.dnsfilter.com/hc/en-us/articles/34957633714707-Uninstall-Windows-Roaming-Client-v2-0-1-or-higher
.LINK
    https://help.dnsfilter.com/hc/en-us/articles/24995915099027-Uninstall-Windows-Roaming-Client-v1-15-3-and-older
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Auto', 'True', 'False')]
    [string]$RegClean = 'Auto',

    [switch]$ForceCleanup,

    [ValidateSet('Clean', 'Report')]
    [string]$DnsCleanup = 'Clean',

    [switch]$TestOnly,

    [switch]$FullMsiLog,

    [ValidateRange(10, 500)]
    [int]$LogTailLines = 40,

    [string]$LogPath = "$env:ProgramData\iTech\Logs\DNSFilter-Uninstall-$env:COMPUTERNAME.log"
)

# Baked commit fallback (replaced by CI)
$Script:GIT_COMMIT = '@GIT_COMMIT@'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:ExitCode = 0
$script:WorkDir  = $null

$commitDisplay = 'unstamped'
if ($Script:GIT_COMMIT -and $Script:GIT_COMMIT -notmatch '^@') { $commitDisplay = $Script:GIT_COMMIT }

# Product codes published in DNSFilter's own uninstall script.
$script:KnownProductCodes = @(
    [pscustomobject]@{ ProductCode = '{4E66DFE1-8225-4ED8-9C7F-6A56E4125018}'; Name = 'DNSFilter Agent' },
    [pscustomobject]@{ ProductCode = '{005C7475-188C-42C4-A8BB-BA5D85258289}'; Name = 'DNS Agent' }
)

$script:ServiceNames = @('DNSFilter Agent', 'DNS Agent')

$script:Result = [ordered]@{
    script      = 'Uninstall-DNSFilterAgent'
    commit      = $commitDisplay
    computer    = $env:COMPUTERNAME
    when        = (Get-Date).ToString('o')
    action      = 'none'
    status      = 'not-started'
    agents      = @()
    removed     = @()
    residue     = @()
    dns         = @()
    exitCode    = 0
    detail      = $null
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
# Discovery helpers
# --------------------------------------------------------------------------
function Open-RegistryView {
    param(
        [Parameter(Mandatory)][ValidateSet('Registry64', 'Registry32')][string]$View
    )
    try {
        return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    } catch {
        return $null
    }
}

function Get-MsiProducts {
    # The Windows Installer database. Independent of Add/Remove Programs, so this
    # is how a product installed with ARPSYSTEMCOMPONENT=1 is still found. The COM
    # API is used rather than Win32_Product: the WMI class triggers a consistency
    # check against every installed product, this does not.
    $found = @()
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        $codes = @($installer.GetType().InvokeMember('Products', 'GetProperty', $null, $installer, $null))
        foreach ($code in $codes) {
            if (-not $code) { continue }
            $name = ''
            $version = ''
            # ProductInfo is a read-only indexed property on the Installer object,
            # not a method: it must be read with GetProperty and index arguments, or
            # the call throws, the exception is swallowed, and this whole discovery
            # source silently returns nothing.
            try { $name = [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'ProductName')) } catch { }
            try { $version = [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'VersionString')) } catch { }
            if (-not $name) { continue }
            $found += [pscustomobject]@{
                ProductCode = ([string]$code).ToUpper()
                Name        = $name
                Version     = $version
                Publisher   = ''
                View        = 'machine'
                Source      = 'MsiDatabase'
            }
        }
    } catch {
        # No Windows Installer COM on this host; the other discovery sources stand.
        return @()
    } finally {
        if ($installer) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) } catch { }
        }
    }
    return $found
}

function Get-UninstallEntries {
    # Add/Remove Programs for one view. Hidden (ARPSYSTEMCOMPONENT=1) installs are
    # absent here, which is why discovery has other sources.
    param([Parameter(Mandatory)][ValidateSet('Registry64', 'Registry32')][string]$View)
    $base = Open-RegistryView -View $View
    if (-not $base) { return @() }
    $root = $null
    $found = @()
    try {
        $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        if (-not $root) { return @() }
        foreach ($name in $root.GetSubKeyNames()) {
            $child = $null
            try {
                $child = $root.OpenSubKey($name)
                if (-not $child) { continue }
                $display = $child.GetValue('DisplayName')
                if (-not $display) { continue }
                $found += [pscustomobject]@{
                    ProductCode = $name
                    Name        = [string]$display
                    Version     = [string]$child.GetValue('DisplayVersion')
                    Publisher   = [string]$child.GetValue('Publisher')
                    View        = $View
                    Source      = 'ARP'
                }
            } catch {
                continue
            } finally {
                if ($child) { $child.Dispose() }
            }
        }
    } catch {
        return @()
    } finally {
        if ($root) { $root.Dispose() }
        $base.Dispose()
    }
    return $found
}

function Get-RegistryGuids {
    # The KB's manual route: a GUID stored under the agent's own key. The value
    # name has changed between builds, so scan values and subkey names for the
    # GUID shape rather than assuming one.
    $found = @()
    foreach ($view in @('Registry64', 'Registry32')) {
        $base = Open-RegistryView -View $view
        if (-not $base) { continue }
        foreach ($path in @('SOFTWARE\DNSFilter\Agent', 'SOFTWARE\DNSAgent\Agent')) {
            $key = $null
            try {
                $key = $base.OpenSubKey($path)
                if (-not $key) { continue }
                foreach ($valueName in $key.GetValueNames()) {
                    $data = [string]$key.GetValue($valueName)
                    if ($data -match '^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$') {
                        $code = $data.Trim()
                        if (-not $code.StartsWith('{')) { $code = '{' + $code + '}' }
                        $found += [pscustomobject]@{
                            ProductCode = $code.ToUpper()
                            Name        = ''
                            Version     = ''
                            Publisher   = ''
                            View        = $view
                            Source      = ('Registry:' + $valueName)
                        }
                    }
                }
                foreach ($sub in $key.GetSubKeyNames()) {
                    if ($sub -match '^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$') {
                        $code = $sub
                        if (-not $code.StartsWith('{')) { $code = '{' + $code + '}' }
                        $found += [pscustomobject]@{
                            ProductCode = $code.ToUpper()
                            Name        = ''
                            Version     = ''
                            Publisher   = ''
                            View        = $view
                            Source      = 'Registry:subkey'
                        }
                    }
                }
            } catch {
                continue
            } finally {
                if ($key) { $key.Dispose() }
            }
        }
        $base.Dispose()
    }
    return $found
}

function Get-AgentServices {
    $found = @()
    foreach ($name in $script:ServiceNames) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            $found += [pscustomobject]@{ Name = $svc.Name; Status = [string]$svc.Status }
        } catch { }
    }
    return $found
}

function Get-ProgramFileRoots {
    # A 32-bit PowerShell host on 64-bit Windows reports ProgramFiles as
    # "Program Files (x86)", so the native directory would be missed. ProgramW6432
    # is the native root even from a 32-bit host; collect every root that exists and
    # use the same list for discovery and for cleanup.
    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) { $roots += $env:ProgramW6432 }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { $roots += $env:ProgramFiles }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { $roots += ${env:ProgramFiles(x86)} }
    return @($roots | Select-Object -Unique)
}

function Get-AgentDirectories {
    # Every programs root that exists, plus the two ProgramData locations the
    # current and legacy builds use.
    $found = @()
    foreach ($root in (Get-ProgramFileRoots)) {
        foreach ($leaf in @('DNSFilter Agent', 'DNS Agent')) {
            $p = Join-Path -Path $root -ChildPath $leaf
            if (Test-Path -LiteralPath $p) { $found += $p }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        foreach ($leaf in @('DNSFilter, Inc', 'DNS Agent')) {
            $p = Join-Path -Path $env:ProgramData -ChildPath $leaf
            if (Test-Path -LiteralPath $p) { $found += $p }
        }
    }
    return @($found | Select-Object -Unique)
}

function Get-PhysicalResidue {
    # Services and program-files directories a complete removal should have taken
    # away. ProgramData configuration is excluded when it was asked to be preserved.
    param([switch]$PreserveConfig)
    $items = @()
    foreach ($svc in (Get-AgentServices)) { $items += ('service:' + $svc.Name) }
    $configDirs = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $configDirs += (Join-Path $env:ProgramData 'DNSFilter, Inc')
        $configDirs += (Join-Path $env:ProgramData 'DNS Agent')
    }
    foreach ($dir in (Get-AgentDirectories)) {
        if ($PreserveConfig -and ($configDirs -contains $dir)) { continue }
        $items += ('dir:' + $dir)
    }
    return $items
}

function Test-ProductRegistered {
    # Registration only: Add/Remove Programs and the Windows Installer database.
    # The HKLM\SOFTWARE\DNSFilter\Agent GUID is deliberately excluded - it is
    # configuration, and with -RegClean False it is meant to survive the removal.
    param([Parameter(Mandatory)][string]$ProductCode)
    $code = $ProductCode.ToUpper()
    foreach ($view in @('Registry64', 'Registry32')) {
        foreach ($entry in (Get-UninstallEntries -View $view)) {
            if ($entry.ProductCode.ToUpper() -eq $code) { return $true }
        }
    }
    foreach ($product in (Get-MsiProducts)) {
        if ($product.ProductCode -eq $code) { return $true }
    }
    return $false
}

function Get-AgentRecipe {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return 'unknown' }
    try {
        if ([version]$Version -ge [version]'2.0.1') { return 'modern' }
        return 'legacy'
    } catch {
        return 'unknown'
    }
}

function Get-InstalledAgents {
    # Union of every discovery source, deduplicated by product code.
    $candidates = @()
    foreach ($view in @('Registry64', 'Registry32')) {
        $candidates += Get-UninstallEntries -View $view
    }
    $candidates += Get-MsiProducts
    $candidates += Get-RegistryGuids

    $matched = @()
    foreach ($c in $candidates) {
        $isAgent = $false
        if ($c.Name -match 'DNSFilter|DNS\s*Agent') { $isAgent = $true }
        elseif ($c.Publisher -match 'DNSFilter') { $isAgent = $true }
        elseif ($c.Source -like 'Registry*') { $isAgent = $true }   # the key itself is the agent's
        if (-not $isAgent) { continue }
        # Guard against unrelated products that merely contain "DNS Agent".
        if ($c.Name -and $c.Name -notmatch 'DNSFilter' -and $c.Publisher -notmatch 'DNSFilter') {
            if ($c.Name -notmatch '^DNS\s*Agent') { continue }
        }
        $matched += $c
    }

    # Real discovery sources are not synthetic; the known-code fallback below is.
    foreach ($m in $matched) {
        if (-not ($m.PSObject.Properties.Name -contains 'Synthetic')) {
            $m | Add-Member -NotePropertyName Synthetic -NotePropertyValue $false -Force
        }
    }

    # Anything visible on disk or in services but not yet identified gets the known codes.
    $seenCodes = @($matched | ForEach-Object { $_.ProductCode.ToUpper() })
    $hasSomething = (Get-AgentServices).Count -gt 0 -or (Get-AgentDirectories).Count -gt 0
    if ($hasSomething) {
        foreach ($known in $script:KnownProductCodes) {
            if ($seenCodes -notcontains $known.ProductCode.ToUpper()) {
                $matched += [pscustomobject]@{
                    ProductCode = $known.ProductCode
                    Name        = $known.Name
                    Version     = ''
                    Publisher   = 'DNSFilter'
                    View        = ''
                    Source      = 'KnownProductCode'
                    Synthetic   = $true
                }
            }
        }
    }

    $unique = @{}
    foreach ($m in $matched) {
        $code = $m.ProductCode.ToUpper()
        if (-not $unique.ContainsKey($code)) {
            $unique[$code] = $m
        } else {
            $existing = $unique[$code]
            if (-not $existing.Version -and $m.Version) { $existing.Version = $m.Version }
            if (-not $existing.Name -and $m.Name) { $existing.Name = $m.Name }
            if ($existing.Source -notlike '*MsiDatabase*') { $existing.Source = $existing.Source + '+' + $m.Source }
            # A real source beats the fallback: the product is genuinely registered.
            if ($m.Synthetic -eq $false) { $existing.Synthetic = $false }
        }
    }

    $agents = @()
    foreach ($key in $unique.Keys) {
        $a = $unique[$key]
        $agents += [pscustomobject]@{
            ProductCode = $a.ProductCode.ToUpper()
            Name        = $a.Name
            Version     = $a.Version
            Source      = $a.Source
            View        = $a.View
            Synthetic   = [bool]$a.Synthetic
            Recipe      = Get-AgentRecipe -Version $a.Version
        }
    }
    return @($agents | Sort-Object Name, ProductCode)
}

# --------------------------------------------------------------------------
# Removal helpers
# --------------------------------------------------------------------------
function Invoke-Msi {
    param([Parameter(Mandatory)][string]$Arguments)
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    return [int]$proc.ExitCode
}

function Get-MsiOutcome {
    param([Parameter(Mandatory)][int]$Code)
    switch ($Code) {
        0    { return [pscustomobject]@{ Ok = $true;  Note = 'Removal succeeded' } }
        3010 { return [pscustomobject]@{ Ok = $true;  Note = 'Removal succeeded, reboot required' } }
        1641 { return [pscustomobject]@{ Ok = $true;  Note = 'Removal succeeded, restart initiated' } }
        1605 { return [pscustomobject]@{ Ok = $true;  Note = '1605 product is not installed; treating as already removed' } }
        1603 { return [pscustomobject]@{ Ok = $false; Note = '1603 fatal error during removal; read the MSI log' } }
        1618 { return [pscustomobject]@{ Ok = $false; Note = '1618 another installation is in progress; retry later' } }
        1619 { return [pscustomobject]@{ Ok = $false; Note = '1619 package could not be opened' } }
        1625 { return [pscustomobject]@{ Ok = $false; Note = '1625 removal forbidden by policy; check AppLocker or Software Restriction Policies' } }
        1639 { return [pscustomobject]@{ Ok = $false; Note = '1639 invalid command line argument' } }
        default { return [pscustomobject]@{ Ok = $false; Note = ('msiexec returned {0}' -f $Code) } }
    }
}

function Write-MsiLogDigest {
    # Echo the interesting parts of /l*vx! to STDOUT so the RMM task carries the
    # evidence; the whole file stays on disk for support.
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][int]$TailLines,
        [switch]$Full
    )
    if (-not (Test-Path -LiteralPath $LogFile)) {
        Write-Log -Level WARN -Message ('msiexec log was not created: {0}' -f $LogFile)
        return
    }
    $lines = @()
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $lines = @(Get-Content -LiteralPath $LogFile -ErrorAction Stop)
                break
            } catch {
                Start-Sleep -Milliseconds 300
            }
        }
    } catch {
        Write-Log -Level WARN -Message ('Could not read the msiexec log: {0}' -f $_.Exception.Message)
        return
    }
    if ($lines.Count -eq 0) { Write-Log -Level WARN -Message 'msiexec log is empty.'; return }

    if ($Full) {
        Write-Host '--- msiexec log (full) ---'
        $lines | ForEach-Object { Write-Host $_ }
        Write-Host '--- end msiexec log ---'
        return
    }

    $interesting = @($lines | Where-Object {
        $_ -match 'Return value 3|Note: 1: 2262|Error|Failed|Warning|Product: |Removal|Uninstall|REGCLEAN'
    })
    $tail = @($lines | Select-Object -Last $TailLines)
    $combined = @($interesting + '--- tail ---' + $tail) | Select-Object -Unique
    if ($combined.Count -gt 160) { $combined = $combined | Select-Object -First 160 }

    Write-Host ('--- msiexec log digest ({0} lines total, {1} shown) ---' -f $lines.Count, $combined.Count)
    $combined | ForEach-Object { Write-Host $_ }
    Write-Host '--- end digest ---'
}

function Get-ResidueTargets {
    # Residue is per product: removing the legacy client must never delete the
    # modern one's service, directory or registry tree. A candidate with no name
    # (found only by its registry GUID) is ambiguous, so it covers both.
    param([Parameter(Mandatory)]$Agent)
    $branded = [bool]($Agent.Name -match 'DNSFilter')
    $legacy  = [bool]($Agent.Name -match 'Agent' -and $Agent.Name -notmatch 'DNSFilter')
    if (-not $branded -and -not $legacy) { $branded = $true; $legacy = $true }

    $targets = [pscustomobject]@{ Services = @(); Directories = @(); ConfigDirectories = @(); Keys = @() }
    if ($branded) {
        $targets.Services += 'DNSFilter Agent'
        foreach ($root in (Get-ProgramFileRoots)) { $targets.Directories += (Join-Path $root 'DNSFilter Agent') }
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) { $targets.ConfigDirectories += (Join-Path $env:ProgramData 'DNSFilter, Inc') }
        $targets.Keys += 'SOFTWARE\DNSFilter'
    }
    if ($legacy) {
        $targets.Services += 'DNS Agent'
        foreach ($root in (Get-ProgramFileRoots)) { $targets.Directories += (Join-Path $root 'DNS Agent') }
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) { $targets.ConfigDirectories += (Join-Path $env:ProgramData 'DNS Agent') }
        $targets.Keys += 'SOFTWARE\DNSAgent'
    }
    return $targets
}

function Remove-AgentResidue {
    # Service, directories and registry keys for the products named in -Agents.
    # Called once, after every removal attempt, so one product's success cannot
    # clear another product's files first.
    param(
        [Parameter(Mandatory)][object[]]$Agents,
        [switch]$PreserveConfig
    )
    $removed = @()
    $failed  = @()

    $services   = @()
    $dirs       = @()
    $configDirs = @()
    $keys       = @()
    foreach ($agent in $Agents) {
        $targets     = Get-ResidueTargets -Agent $agent
        $services   += $targets.Services
        $dirs       += $targets.Directories
        $configDirs += $targets.ConfigDirectories
        $keys       += $targets.Keys
    }
    $services   = @($services | Select-Object -Unique)
    $dirs       = @($dirs | Select-Object -Unique)
    $configDirs = @($configDirs | Select-Object -Unique)
    $keys       = @($keys | Select-Object -Unique)
    # Preserving the configuration means keeping ProgramData too, not just the keys.
    if (-not $PreserveConfig) { $dirs = @($dirs + $configDirs | Select-Object -Unique) }

    foreach ($name in $services) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            if ($svc.Status -eq 'Running') {
                try { Stop-Service -Name $name -Force -ErrorAction Stop } catch {
                    Write-Log -Level WARN -Message ('Could not stop service {0}: {1}' -f $name, $_.Exception.Message)
                }
            }
            $out = & sc.exe delete "$name" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log -Level OK -Message ('Removed leftover service: {0}' -f $name)
                $removed += ('service:' + $name)
            } else {
                Write-Log -Level WARN -Message ('sc.exe delete {0} returned {1}: {2}' -f $name, $LASTEXITCODE, ($out -join ' '))
                $failed += ('service:' + $name)
            }
        } catch { }
    }

    foreach ($path in $dirs) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-Log -Level OK -Message ('Removed leftover directory: {0}' -f $path)
            $removed += ('dir:' + $path)
        } catch {
            Write-Log -Level WARN -Message ('Could not remove {0}: {1}' -f $path, $_.Exception.Message)
            $failed += ('dir:' + $path)
        }
    }

    if ($PreserveConfig) {
        # -RegClean False asked the MSI to keep the agent's registry state, so the
        # script must not delete the tree the MSI was told to preserve.
        Write-Log -Message ('Keeping configuration keys ({0}) because -RegClean False was requested.' -f ($keys -join ', '))
    } else {
        foreach ($view in @('Registry64', 'Registry32')) {
            $base = Open-RegistryView -View $view
            if (-not $base) { continue }
            try {
                foreach ($keyPath in $keys) {
                    try {
                        $key = $base.OpenSubKey($keyPath, $true)
                        if ($key) {
                            $key.Dispose()
                            $base.DeleteSubKeyTree($keyPath)
                            Write-Log -Level OK -Message ('Removed leftover registry key: HKLM\{0} ({1})' -f $keyPath, $view)
                            $removed += ('key:' + $keyPath + ':' + $view)
                        }
                    } catch {
                        # A restrictive ACL on a surviving subkey is the usual cause.
                        # Swallowing it reported the run as clean while the config
                        # tree was still there, so it becomes failed residue.
                        Write-Log -Level WARN -Message ('Could not remove registry key HKLM\{0} ({1}): {2}' -f $keyPath, $view, $_.Exception.Message)
                        $failed += ('key:' + $keyPath + ':' + $view)
                    }
                }
            } catch {
                Write-Log -Level WARN -Message ('Registry cleanup error in {0}: {1}' -f $view, $_.Exception.Message)
                # The view itself failed, so every key it was meant to clear is
                # still unverified - record them rather than reporting success.
                foreach ($keyPath in $keys) { $failed += ('key:' + $keyPath + ':' + $view) }
            } finally {
                $base.Dispose()
            }
        }
    }

    return [pscustomobject]@{ Removed = $removed; Failed = $failed }
}

function Repair-LoopbackDns {
    # The agent points adapters at 127.0.0.1. Left behind, that adapter has no DNS.
    param([ValidateSet('Clean', 'Report')][string]$Mode)
    $results = @()
    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    } catch {
        $message = $_.Exception.Message
        Write-Log -Level WARN -Message ('Could not enumerate adapters: {0}' -f $message)
        # Without an adapter list this run cannot tell whether loopback DNS was
        # left behind. Under Clean that is an uninspected endpoint, not a success;
        # under Report nothing was going to change anyway.
        if ($Mode -eq 'Report') { return $results }
        return @([pscustomobject]@{
            Adapter = '(enumeration)'
            Before  = ''
            After   = ''
            Action  = ('failed:' + $message)
        })
    }
    foreach ($adapter in $adapters) {
        $config = $null
        try {
            $config = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
        } catch {
            $message = $_.Exception.Message
            Write-Log -Level WARN -Message ('Could not read DNS servers for {0}: {1}' -f $adapter.Name, $message)
            if ($Mode -ne 'Report') {
                $results += [pscustomobject]@{
                    Adapter = $adapter.Name
                    Before  = '(unreadable)'
                    After   = ''
                    Action  = ('failed:' + $message)
                }
            }
            continue
        }
        $servers = @($config.ServerAddresses)
        if ($servers.Count -eq 0) { continue }
        $loopback = @($servers | Where-Object { $_ -match '^127\.' })
        if ($loopback.Count -eq 0) { continue }

        $keep = @($servers | Where-Object { $_ -notmatch '^127\.' })
        $action = if ($Mode -eq 'Report') { 'reported' } else { 'pending' }
        if ($Mode -eq 'Clean') {
            try {
                if ($keep.Count -eq 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    $action = 'reset-to-dhcp'
                } else {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $keep -ErrorAction Stop
                    $action = 'loopback-removed'
                }
            } catch {
                $action = 'failed:' + $_.Exception.Message
            }
        }
        $after = @()
        try {
            $after = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
        } catch { }
        $results += [pscustomobject]@{
            Adapter = $adapter.Name
            Before  = ($servers -join ',')
            After   = ($after -join ',')
            Action  = $action
        }
        $logLevel = if ($action -like 'failed*') { 'WARN' } else { 'OK' }
        Write-Log -Level $logLevel -Message ('DNS {0}: {1}  before=[{2}] after=[{3}]' -f $action, $adapter.Name, ($servers -join ','), ($after -join ','))
    }
    return $results
}

# --------------------------------------------------------------------------
# Main workflow
# --------------------------------------------------------------------------
function Invoke-Removal {
    Write-Log -Level INFO -Message ('=== Uninstall-DNSFilterAgent {0} on {1} ===' -f $commitDisplay, $env:COMPUTERNAME)

    $agents = Get-InstalledAgents
    $script:Result.agents = @($agents | ForEach-Object {
        [ordered]@{ product = $_.Name; code = $_.ProductCode; version = $_.Version; foundBy = $_.Source; synthetic = $_.Synthetic; recipe = $_.Recipe }
    })

    if ($agents.Count -eq 0) {
        Write-Log -Level OK -Message 'No DNSFilter agent found: nothing in Add/Remove Programs, the agent registry keys, the MSI product database, or as a service/directory.'
        $script:Result.action = 'none'
        $script:Result.status = 'not-installed'
        $script:ExitCode = 0
        return
    }

    foreach ($a in $agents) {
        Write-Log -Message ('Found {0} {1} code={2} via {3} (synthetic={4}) -> recipe {5}' -f $a.Name, $a.Version, $a.ProductCode, $a.Source, $a.Synthetic, $a.Recipe)
    }

    if ($TestOnly) {
        Write-Log -Level OK -Message ('Pre-flight only. {0} agent(s) would be removed. Nothing was changed.' -f $agents.Count)
        $script:Result.action = 'preflight'
        $script:Result.status = 'preflight-ok'
        $script:ExitCode = 0
        return
    }

    $script:Result.action = 'uninstall'
    $removedList = @()
    $residueList = @()
    $anyFailed = $false
    $removedAgents = @()

    foreach ($agent in $agents) {
        $useRegClean = switch ($RegClean) {
            'True'  { $true }
            'False' { $false }
            default {
                if ($agent.Recipe -eq 'modern') { $true }
                elseif ($agent.Recipe -eq 'legacy') { $false }
                else { $false }
            }
        }

        $script:WorkDir = Join-Path -Path $env:TEMP -ChildPath ('DNSFilterUninst_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
        $msiLog = Join-Path $script:WorkDir ('uninstall_{0}.log' -f ($agent.ProductCode -replace '[{}]', ''))

        $args = '/X"{0}" /qn /norestart /l*vx! "{1}"' -f $agent.ProductCode, $msiLog
        if ($useRegClean) { $args += ' REGCLEAN=true' } elseif ($RegClean -eq 'False') { $args += ' REGCLEAN=false' }

        Write-Log -Message ('msiexec {0}' -f ('/X"{0}" /qn /norestart /l*vx! <log>{1}' -f $agent.ProductCode, $(if ($useRegClean) { ' REGCLEAN=true' } else { '' })))
        $code = Invoke-Msi -Arguments $args
        $outcome = Get-MsiOutcome -Code $code

        Write-Log -Message ('msiexec exit {0}: {1}' -f $code, $outcome.Note)
        Write-MsiLogDigest -LogFile $msiLog -TailLines $LogTailLines -Full:$FullMsiLog

        if (-not $outcome.Ok) {
            $anyFailed = $true
            Write-Log -Level ERROR -Message ('Removal failed for {0} ({1})' -f $agent.Name, $agent.ProductCode)
        } elseif ($code -ne 1605) {
            # 1605 means the product was not registered, so nothing was removed and
            # this candidate must not authorise a residue pass for anything.
            $removedAgents += $agent
        }

        if (Test-Path -LiteralPath $msiLog) {
            try {
                $logDir = Split-Path -Parent $LogPath
                if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                $keepLog = Join-Path $logDir ('DNSFilter-uninstall-{0}.log' -f ($agent.ProductCode -replace '[{}]', ''))
                Copy-Item -LiteralPath $msiLog -Destination $keepLog -Force -ErrorAction Stop
                Write-Log -Message ('Full msiexec log kept at {0}' -f $keepLog)
            } catch {
                Write-Log -Level WARN -Message ('Could not keep the msiexec log: {0}' -f $_.Exception.Message)
            }
        }
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:WorkDir = $null
    }

    # Residue pass runs once, after every removal attempt, and only for products
    # that were actually removed - unless -ForceCleanup explicitly accepts the
    # risk for products that failed.
    $cleanupAgents = @($removedAgents)
    if ($ForceCleanup) {
        $cleanupAgents = @($agents)
        Write-Log -Level WARN -Message '-ForceCleanup set: residue will be cleared for every detected product, including any that failed to uninstall.'
    }

    if ($cleanupAgents.Count -gt 0) {
        $residue = Remove-AgentResidue -Agents $cleanupAgents -PreserveConfig:($RegClean -eq 'False')
        $removedList += $residue.Removed
        $residueList += $residue.Failed
    } elseif ($anyFailed) {
        Write-Log -Level WARN -Message 'Left residue in place because every removal failed. Re-run with -ForceCleanup to remove it anyway.'
    } else {
        # Discovery can be triggered by a surviving service or directory alone, and
        # cleanup is deliberately skipped when nothing reported as registered. Those
        # survivors are still residue and must fail the run.
        Write-Log -Level WARN -Message 'No product was registered, so residue cleanup was skipped; reporting what is still present.'
    }

    # Whatever cleanup intended to remove, say so if it is still there - this covers
    # the skipped path and any deletion that silently failed.
    foreach ($leftover in (Get-PhysicalResidue -PreserveConfig:($RegClean -eq 'False'))) {
        if ($residueList -notcontains $leftover) {
            Write-Log -Level WARN -Message ('Residue still present: {0}' -f $leftover)
            $residueList += $leftover
        }
    }

    # Verify AFTER cleanup, against registration only. A retained configuration GUID
    # (legal under -RegClean False) is not proof that the product is installed.
    $removedCodes = @($removedAgents | ForEach-Object { $_.ProductCode })
    foreach ($agent in $agents) {
        if (Test-ProductRegistered -ProductCode $agent.ProductCode) {
            Write-Log -Level WARN -Message ('{0} is still registered after removal.' -f $agent.ProductCode)
            $residueList += ('still-registered:' + $agent.ProductCode)
        } elseif ($removedCodes -contains $agent.ProductCode) {
            $removedList += ('product:' + $agent.ProductCode)
        }
    }

    # Leftover HKCU tray icons belong to the logged-on user, not to SYSTEM.
    $trayKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification\StartupTNotiDNSFilter Agent TrayIcon',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification\StartupTNotiDNS Agent TrayIcon'
    )
    $trayFound = @($trayKeys | Where-Object { Test-Path -LiteralPath $_ })
    if ($trayFound.Count -gt 0) {
        Write-Log -Level WARN -Message ('Per-user tray residue exists in the current profile only ({0}). A SYSTEM task cannot clean other users'' hives; clear it per user if the tray icon lingers.' -f ($trayFound -join '; '))
        $residueList += 'hkcu-tray-per-user'
    }

    $script:Result.removed = @($removedList | Select-Object -Unique)
    $script:Result.residue = @($residueList | Select-Object -Unique)

    $dnsResults = Repair-LoopbackDns -Mode $DnsCleanup
    $script:Result.dns = @($dnsResults)

    $dnsFailures = @($dnsResults | Where-Object { $_.Action -like 'failed*' })
    if ($dnsFailures.Count -gt 0) {
        # An adapter still pointing at a loopback resolver after the agent is gone
        # is a broken endpoint, and an adapter that could not be read is uninspected.
        # Neither may report success.
        $residueList += 'dns-cleanup-failed'
        $script:Result.residue = @($residueList | Select-Object -Unique)
        Write-Log -Level ERROR -Message ('{0} adapter(s) could not be inspected or repaired; DNS may still point at loopback.' -f $dnsFailures.Count)
    }

    if ($anyFailed -or $script:Result.residue.Count -gt 0) {
        $script:Result.status = if ($anyFailed) { 'failed' } else { 'removed-with-residue' }
        $script:ExitCode = 1
    } else {
        $script:Result.status = 'removed'
        $script:ExitCode = 0
    }
    $script:Result.detail = ('removed {0}; residue {1}' -f $script:Result.removed.Count, $script:Result.residue.Count)
    Write-Log -Level $(if ($script:ExitCode -eq 0) { 'OK' } else { 'ERROR' }) -Message ('Finished: status={0} removed={1} residue={2}' -f $script:Result.status, $script:Result.removed.Count, $script:Result.residue.Count)
}

try {
    Invoke-Removal
}
catch {
    Write-Log -Level ERROR -Message ('Unhandled failure: {0}' -f $_.Exception.Message)
    $script:Result.status = 'error'
    $script:Result.detail = $_.Exception.Message
    $script:ExitCode = 1
}
finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Single exit point: every completion path reaches this.
$script:Result.exitCode = $script:ExitCode
$script:Result | ConvertTo-Json -Compress -Depth 5
exit $script:ExitCode
