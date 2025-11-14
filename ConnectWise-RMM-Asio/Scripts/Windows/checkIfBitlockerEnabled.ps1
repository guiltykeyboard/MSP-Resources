#Requires -Version 5.1
<#
.SYNOPSIS
  Return 1 if any **non‑removable** (fixed) drives have BitLocker enabled; otherwise 0.
.DESCRIPTION
  Built for CW RMM (ConnectWise RMM - Asio) to run on a schedule (e.g., weekly) and feed a
  Yes/No custom field. The script inspects **fixed/local** drives only (excludes removable
  USB flash drives, optical, network, RAM disks) and checks BitLocker status per volume.

  Output is a **single line**: `1` if any fixed drive has BitLocker protection **On**,
  else `0`. Use this in CW RMM automation to set a boolean/flag custom field.

  Implementation details:
  - Prefers `Get-BitLockerVolume` when available.
  - Falls back to `manage-bde -status` for older hosts.
  - Runs fine as SYSTEM (no local files created). In mixed scenarios, it can self‑elevate
    when not already elevated unless `-NoElevate` is supplied.

.PARAMETER NoElevate
  Skip self‑elevation if not already elevated.

.OUTPUTS
  System.String — "1" or "0" on STDOUT for easy parsing by CW RMM.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\checkIfBitlockerEnabled.ps1
  # 1  (means at least one fixed drive has BitLocker enabled)
#>


param(
  [switch]$NoElevate,
  [switch]$SelfUpdated  # internal guard to avoid update loops
)

# Baked commit fallback (replaced by CI); leave placeholder literally as b63ba6e6b923a638b04ebbda615acd0092fd3380
$Script:GIT_COMMIT = 'b63ba6e6b923a638b04ebbda615acd0092fd3380'

# --- Metadata / Source Info --------------------------------------------------
try {
  $scriptPath = $PSCommandPath
  $commitHash = ''
  $gitRoot = (Get-Item $scriptPath).Directory.FullName
  while (-not (Test-Path (Join-Path $gitRoot '.git')) -and (Split-Path $gitRoot) -ne $gitRoot) {
    $gitRoot = Split-Path $gitRoot
  }
  if (Test-Path (Join-Path $gitRoot '.git')) {
    $commitHash = (git -C $gitRoot rev-parse --short HEAD 2>$null)
  }
  if (-not $commitHash -and $Script:GIT_COMMIT -and $Script:GIT_COMMIT -ne 'b63ba6e6b923a638b04ebbda615acd0092fd3380') {
    $commitHash = $Script:GIT_COMMIT
  }
  $msg = "SCRIPT SOURCE: $scriptPath"
  if ($commitHash) { $msg += " (Git commit: $commitHash)" }
  Write-Output $msg
} catch {
  Write-Output "SCRIPT SOURCE: $PSCommandPath (Git info unavailable)"
}

# Self-update helpers
function Get-RepoLatestShortSHA {
  param([string]$Repo = 'guiltykeyboard/MSP-Resources', [string]$Ref = 'main')
  try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $uri = "https://api.github.com/repos/$Repo/commits/$Ref"
    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -Headers @{ 'User-Agent'='MSP-Resources-SelfUpdate' } -ErrorAction Stop
    $json = $resp.Content | ConvertFrom-Json
    $sha = $json.sha
    if ($sha -and $sha.Length -ge 7) { return $sha.Substring(0,7) }
  } catch { }
  return $null
}
function Invoke-SelfUpdateIfOutdated {
  param(
    [Parameter(Mandatory)][string]$RepoRelPath,
    [string]$Repo = 'guiltykeyboard/MSP-Resources',
    [string]$Ref = 'main',
    [switch]$Skip
  )
  if ($Skip) { return }
  $latest = Get-RepoLatestShortSHA -Repo $Repo -Ref $Ref
  if (-not $latest) { return }
  $current = $commitHash
  if (-not $current) { $current = $Script:GIT_COMMIT }
  if ($current -and $latest -eq $current) { return }
  try {
    $rawBase = "https://raw.githubusercontent.com/$Repo/$Ref"
    $url = "$rawBase/$RepoRelPath"
    $tmp = Join-Path $env:TEMP ("{0}-{1}.ps1" -f ([IO.Path]::GetFileNameWithoutExtension($RepoRelPath)), $latest)
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp -ErrorAction Stop

    # Integrity verification using GitHub API SHA
    try {
      $shaApi = "https://api.github.com/repos/$Repo/contents/$RepoRelPath?ref=$Ref"
      $shaResp = Invoke-WebRequest -UseBasicParsing -Uri $shaApi -Headers @{ 'User-Agent'='MSP-Resources-SelfUpdate' } -ErrorAction Stop
      $shaJson = $shaResp.Content | ConvertFrom-Json
      $expectedSha = $shaJson.sha
      if ($expectedSha) {
        $actualSha = [System.BitConverter]::ToString((Get-FileHash -Path $tmp -Algorithm SHA256).Hash).Replace('-', '').ToLowerInvariant()
        if (-not ($actualSha.StartsWith($expectedSha.Substring(0,7)))) {
          throw "Integrity check failed for downloaded script. Expected SHA prefix $($expectedSha.Substring(0,7)), got $($actualSha.Substring(0,7))."
        } else {
          Write-Output "SELF-UPDATE: Integrity verified ($($expectedSha.Substring(0,7)))"
        }
      }
    } catch {
      Write-Warning "SELF-UPDATE: Integrity verification skipped or failed: $($_.Exception.Message)"
    }

    Write-Output "SELF-UPDATE: Downloaded latest script ($latest). Re-launching..."
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tmp`"") +
               ($PSBoundParameters.GetEnumerator() | ForEach-Object {
                 if ($_.Key -eq 'SelfUpdated') { return $null }
                 if ($_.Value -is [switch]) { if ($_.Value) { "-$(
$_.Key)" } }
                 else { "-$(
$_.Key)"; "$(
$_.Value)" }
               }) + '-SelfUpdated'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -NoNewWindow
    exit 0
  } catch {
    Write-Warning "SELF-UPDATE: Failed to download latest script: $($_.Exception.Message). Continuing with local version."
  }
}
Invoke-SelfUpdateIfOutdated -RepoRelPath 'ConnectWise-RMM-Asio/Scripts/Windows/checkIfBitlockerEnabled.ps1' -Skip:$SelfUpdated

function Test-IsElevated {
  try { return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
  catch { return $false }
}

# Elevate when needed (CW RMM as SYSTEM is already elevated)
if (-not $NoElevate -and -not (Test-IsElevated)) {
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit 0
  } catch {
    Write-Warning "Elevation failed or was canceled; continuing without elevation."
  }
}

function Get-FixedDriveLetters {
  # Try modern Get-Volume first
  $letters = @()
  try {
    $letters = Get-Volume -ErrorAction Stop |
      Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
      Select-Object -ExpandProperty DriveLetter
  } catch {
    # Fall back to CIM for older builds
    try {
      $letters = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object { $_.DeviceID -match ':' } |
        ForEach-Object { $_.DeviceID.Substring(0,1) }
    } catch {}
  }
  return @($letters | Sort-Object -Unique)
}

function Get-BitLockerEnabledMap {
  param([string[]]$DriveLetters)
  $map = @{}

  $blCmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
  if ($blCmd) {
    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue

    # Build a lookup by drive letter (normalize MountPoint: "C:" or "C:\" -> "C")
    $volsByLetter = @{}
    foreach ($v in $vols) {
      $mp = $null
      try { $mp = ($v.MountPoint).ToString() } catch { $mp = $null }
      if ($mp) {
        $mp = $mp.TrimEnd('\')
        if ($mp.Length -ge 2 -and $mp[1] -eq ':') {
          $letter = $mp.Substring(0,1).ToUpper()
          if ($letter -match '^[A-Z]$') { $volsByLetter[$letter] = $v }
        }
      }
    }

    foreach ($dl in $DriveLetters) {
      $present = Test-Path ("${dl}:\")
      $enabled = $false
      if ($present) {
        $v = $volsByLetter[$dl.ToUpper()]
        if ($null -ne $v) {
          # ProtectionStatus is an enum; ToString() yields 'On' when protected
          $enabled = ($v.ProtectionStatus.ToString() -eq 'On')
        } else {
          # Fallback to manage-bde parsing if not found in the lookup
          $enabled = (Get-ManageBdeEnabled -Drive $dl)
        }
      }
      $map[$dl] = $enabled
    }
  } else {
    foreach ($dl in $DriveLetters) {
      $map[$dl] = (Get-ManageBdeEnabled -Drive $dl)
    }
  }
  return $map
}

function Get-ManageBdeEnabled {
  param([Parameter(Mandatory)] [ValidatePattern('^[A-Fa-f]$')] [string]$Drive)
  $present = Test-Path ("${Drive}:\")
  if (-not $present) { return $false }
  try {
    $raw = & manage-bde -status "${Drive}:\\" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $false }
    $prot = ($raw | Select-String -Pattern 'Protection\s*Status\s*:\s*(.*)' -AllMatches | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Select-Object -First 1)
    return ($prot -match 'On')
  } catch { return $false }
}

# --- main ---
$fixedLetters = Get-FixedDriveLetters
$bitlockerMap = Get-BitLockerEnabledMap -DriveLetters $fixedLetters
$anyEnabledFixed = $null -ne ($bitlockerMap.Values | Where-Object { $_ }) -and (($bitlockerMap.Values | Where-Object { $_ }).Count -gt 0)

# Emit a single, parseable marker line (some RMM UIs display only the last line)
Write-Output ([int]$anyEnabledFixed)

exit 0