[CmdletBinding()]
param(
  [string]$Keep = 'en-us',
  [switch]$WhatIf,
  [switch]$SelfUpdated,              # internal guard to avoid update loops
  [string]$RepoRelPath,              # optional: allow RMM launchers to pass repo path without error
  [string]$Repo = 'guiltykeyboard/MSP-Resources',
  [string]$Ref  = 'main'
)


<#
.SYNOPSIS
Removes all non-English Microsoft 365 and OneNote language packs using Winget, Appx, or Office Deployment Tool.
.DESCRIPTION
This script identifies and removes all additional Microsoft 365 and OneNote language packs except the one specified with -Keep (default: en-us). 
It supports ConnectWise RMM (ASIO) and console execution modes, automatically selecting the correct cleanup method.
#>

# Baked commit fallback (replaced by CI); leave placeholder literally as 1e57416117967e0a7287b9fd55afb487a3288a16
$Script:GIT_COMMIT = '1e57416117967e0a7287b9fd55afb487a3288a16'

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
  if (-not $commitHash -and $Script:GIT_COMMIT -and $Script:GIT_COMMIT -ne '1e57416117967e0a7287b9fd55afb487a3288a16') {
    $commitHash = $Script:GIT_COMMIT
  }
  $msg = "SCRIPT SOURCE: $scriptPath"
  if ($commitHash) { $msg += " (Git commit: $commitHash)" }
  Write-Output $msg
} catch {
  Write-Output "SCRIPT SOURCE: $PSCommandPath (Git info unavailable)"
}

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


# Allow launcher-provided overrides but default to this script's known path
$__RepoRelPath = if ($PSBoundParameters.ContainsKey('RepoRelPath') -and $RepoRelPath) {
  $RepoRelPath
} else {
  'ConnectWise-RMM-Asio/Scripts/Windows/M365Cleanup.ps1'
}
Invoke-SelfUpdateIfOutdated -RepoRelPath $__RepoRelPath -Repo $Repo -Ref $Ref -Skip:$SelfUpdated

# --- RMM / Console detection --------------------------------------------------
function Test-IsCWRMM {
  return ($env:ASIO -or $env:CONNECTWISE_RMM -or $env:CW_CONTROL -or $env:SCREENCONNECT_URL) `
         -or ($env:ProgramData -match 'ConnectWise') `
         -or ($env:Path -match 'ConnectWise\\RMM')
}

$IsCWRMM = Test-IsCWRMM
$IsInteractive = ($Host.Name -eq 'ConsoleHost' -and -not $IsCWRMM)
$ProgressPreference = if ($IsCWRMM) { 'SilentlyContinue' } else { 'Continue' }

function Stamp([string]$msg) {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Write-Output "$ts $msg"
}

function Show-Progress([string]$activity,[string]$status,[int]$pct) {
  if ($IsInteractive) {
    Write-Progress -Activity $activity -Status $status -PercentComplete $pct
  }
  Stamp "$activity :: $status ($pct%)"
}

# --- Helpers ------------------------------------------------------------------
$Keep = $Keep.ToLower()
$wingetPrefixes = @(
  '^Microsoft 365 - (?<lang>[a-z]{2}-[a-z]{2})\b',
  '^OneNote - (?<lang>[a-z]{2}-[a-z]{2})\b',
  '^Microsoft OneNote - (?<lang>[a-z]{2}-[a-z]{2})\b'
)

# --- Click-to-Run (C2R) / ODT helpers ----------------------------------------
function Get-C2RProductId {
  $cfgPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
  try {
    $p = Get-ItemProperty -Path $cfgPath -ErrorAction Stop
    if ($p.ProductReleaseIds) { return ($p.ProductReleaseIds -split '\s+')[0] }
  } catch { }
  return $null
}

function Get-InstalledC2RLanguages {
  $langs = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

  # Try ClickToRun configuration first
  $cfgPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
  try {
    $p = Get-ItemProperty -Path $cfgPath -ErrorAction Stop
    foreach ($k in 'Language','ProofingToolsCulture','InstallLanguage','FallbackCulture') {
      if ($p.$k) {
        ($p.$k -split '[\s,;]+' | Where-Object { $_ -match '^[a-z]{2}(-|_)[a-z]{2}$' }) | ForEach-Object { [void]$langs.Add($_.ToLower()) }
      }
    }
  } catch { }

  # Also sweep ARP uninstall entries which often surface as "Microsoft 365 - de-de"
  $uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  foreach ($root in $uninstallRoots) {
    try {
      Get-ChildItem $root -ErrorAction Stop | ForEach-Object {
        try {
          $dn = (Get-ItemProperty $_.PsPath -Name DisplayName -ErrorAction Stop).DisplayName
          if ($dn -match '^Microsoft 365\s*-\s*(?<lang>[a-z]{2}-[a-z]{2})$') {
            [void]$langs.Add($Matches['lang'].ToLower())
          }
          elseif ($dn -match '^Microsoft OneNote\s*-\s*(?<lang>[a-z]{2}-[a-z]{2})$' -or $dn -match '^OneNote\s*-\s*(?<lang>[a-z]{2}-[a-z]{2})$') {
            [void]$langs.Add($Matches['lang'].ToLower())
          }
        } catch { }
      }
    } catch { }
  }
  # Return as array
  return @($langs)
}


function Remove-WithODT {
  param([string]$KeepLang, [switch]$WhatIf)

  $productId = Get-C2RProductId
  if (-not $productId) {
    Stamp "[odt] No Click-to-Run product detected; skipping ODT removal."
    return @()
  }

  # Determine installed languages and compute removals
  $allLangs = Get-InstalledC2RLanguages
  $removeLangs = @()
  foreach ($l in $allLangs) { if ($l -ne $KeepLang.ToLower()) { $removeLangs += $l } }

  if (-not $removeLangs) {
    Stamp "[odt] No non-$KeepLang languages detected for $productId."
    return @()
  }

  $work = Join-Path $env:TEMP ("ODT_" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  try {
    # Resolve likely locations
    $scriptDir = Split-Path -Parent $PSCommandPath

    # 1) Try to find an existing setup.exe (script dir, work dir, TEMP tree)
    $setup = @(
      Get-ChildItem -LiteralPath $scriptDir -Filter 'setup.exe' -File -ErrorAction SilentlyContinue
      Get-ChildItem -LiteralPath $work      -Filter 'setup.exe' -File -ErrorAction SilentlyContinue
      Get-ChildItem -Path $env:TEMP -Filter 'setup.exe' -Recurse -ErrorAction SilentlyContinue
    ) | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue

    if (-not $setup) {
      # 2) No setup.exe; try extracting from any local officedeploymenttool*.exe we can find
      $odt = @(
        Get-ChildItem -LiteralPath $scriptDir -Filter 'officedeploymenttool*.exe' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $work      -Filter 'officedeploymenttool*.exe' -File -ErrorAction SilentlyContinue
        Get-ChildItem -Path $env:TEMP -Filter 'officedeploymenttool*.exe' -Recurse -ErrorAction SilentlyContinue
      ) | Sort-Object LastWriteTime -Descending | Select-Object -First 1

      if ($odt) {
        Stamp "[odt] Extracting from: $($odt.FullName)"
        try {
          & $odt.FullName /quiet /extract:$work | Out-Null
        } catch {
          Stamp "[odt] Extraction failed: $($_.Exception.Message)"
        }

        # Re-scan workdir recursively for setup.exe
        $setup = Get-ChildItem -Path $work -Filter 'setup.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
      }
    }

    if (-not $setup) {
      throw "[odt] setup.exe not found. Place setup.exe or officedeploymenttool*.exe next to the script and re-run."
    }

    # Normalize setup path (coerce to single string, remove stray quotes/whitespace)
    $setup = [string]($setup | Select-Object -First 1)
    $setup = $setup.Trim().Trim('""')

    # Sanity check and diagnostics
    if (-not (Test-Path -LiteralPath $setup)) {
      Stamp "[odt] ERROR: setup.exe path not found: $setup"
      throw "[odt] setup.exe path not found"
    }
    Stamp "[odt] setup.exe resolved to: $setup"
    try {
      $info = Get-Item -LiteralPath $setup -ErrorAction Stop
      Stamp "[odt] setup.exe size: $([int]$info.Length) bytes; Modified: $($info.LastWriteTime)"
    } catch {
      Stamp "[odt] WARNING: Unable to stat setup.exe: $($_.Exception.Message)"
    }

    # Prepare working directory for launch
    $wd = [string](Split-Path -Parent $setup)

    # Build config XML
    $xmlPath = Join-Path $work 'remove_langs.xml'
    $xml = @()
    $xml += '<Configuration>'
    $xml += '  <Remove>'
    $xml += "    <Product ID=""$productId"">"
    foreach ($l in $removeLangs) { $xml += "      <Language ID=""$l"" />" }
    $xml += '    </Product>'
    $xml += '  </Remove>'
    $xml += '  <Display Level="None" AcceptEULA="TRUE" />'
    $xml += '</Configuration>'
    $xml -join "`r`n" | Set-Content -Path $xmlPath -Encoding UTF8

    Stamp "[odt] Product: $productId  Pending language removals: $($removeLangs -join ', ')"
    if ($WhatIf) {
      Stamp "[odt] (WhatIf) $setup /configure $xmlPath"
      return $removeLangs
    }

    # Run setup.exe /configure with robust fallback
    Stamp "[odt] Launching: $setup /configure `"$xmlPath`" (WD=$wd)"
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $setup
      $psi.Arguments = "/configure `"$xmlPath`""
      $psi.WorkingDirectory = $wd
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError  = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $out = $p.StandardOutput.ReadToEnd()
      $err = $p.StandardError.ReadToEnd()
      # Monitor progress while ODT runs (interactive console only)
      if ($IsInteractive) {
        Stamp "[odt] Monitoring ODT progress..."
        while (-not $p.HasExited) {
          try {
            $pp = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
          } catch { $pp = $null }
          if ($pp) {
            $cpu = [math]::Round($pp.CPU, 1)
            $mem = [math]::Round($pp.WorkingSet / 1MB, 1)
            Stamp "[odt] Running (CPU: $cpu sec, MEM: $mem MB)"
          }
          Start-Sleep -Seconds 5
        }
        if ($IsInteractive) { Write-Progress -Activity "Office Deployment Tool" -Status "Completed" -Completed }
      } else {
        # Under RMM: just wait quietly; output will be captured as normal log lines
        $p.WaitForExit()
      }
      if ($out) { $out -split "`r?`n" | Where-Object {$_} | ForEach-Object { Stamp "[odt] $_" } }
      if ($err) { $err -split "`r?`n" | Where-Object {$_} | ForEach-Object { Stamp "[odt] $_" } }
      Stamp "[odt] ExitCode: $($p.ExitCode)"
    } catch {
      Stamp "[odt] Start via ProcessStartInfo failed: $($_.Exception.Message)"
      # Fallback: use call operator
      try {
        Push-Location -LiteralPath $wd
        & $setup /configure "$xmlPath"
        $ec = $LASTEXITCODE
        Pop-Location
        Stamp "[odt] Fallback (&) exit code: $ec"
      } catch {
        Stamp "[odt] Fallback (&) failed: $($_.Exception.Message)"
        # Final fallback: try Start-Process -PassThru
        try {
          $sp = Start-Process -FilePath ($setup | Select-Object -First 1) -ArgumentList "/configure `"$xmlPath`"" -WorkingDirectory ([string]$wd) -PassThru -NoNewWindow -ErrorAction Stop
          $sp.WaitForExit()
          Stamp "[odt] Start-Process exit code: $($sp.ExitCode)"
        } catch {
          Stamp "[odt] Start-Process fallback failed: $($_.Exception.Message)"
          throw
        }
      }
    }

    return $removeLangs
  } finally {
    try { Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
}

# --- Winget path (preferred) --------------------------------------------------
function Remove-WithWinget {
  param([string]$KeepLang, [string[]]$NamePatterns, [switch]$WhatIf)

  try { $null = winget --version 2>$null } catch { Stamp "[winget] Not available."; return @() }

  $rows = winget list --source msstore 2>$null
  if (-not $rows) { return @() }

  $targets = @()
  foreach ($pattern in $NamePatterns) {
    $hits = $rows | Select-String -Pattern $pattern
    foreach ($h in $hits) {
      if ($h.Line -match $pattern) {
        $lang = $Matches['lang'].ToLower()
        if ($lang -ne $KeepLang.ToLower()) {
          # The exact name is the left-most column; use a safe slice from the matched portion
          # Here we assume the matched text begins with the exact product name we can pass to --name
          $name = $h.Matches[0].Value -replace '\s+$',''
          $targets += [pscustomobject]@{ Name = $name; Lang = $lang; Method = 'winget' }
        }
      }
    }
  }

  if (-not $targets) { return @() }

  Stamp "[winget] Total items pending removal: $($targets.Count)"

  $i = 0
  foreach ($t in $targets) {
    $i++
    $remaining = $targets.Count - $i + 1
    Stamp "[winget] Remaining: $remaining of $($targets.Count)"
    $pct = [int](($i / $targets.Count) * 100)
    Show-Progress "Removing MS 365/OneNote language packs (winget)" "$($t.Lang) $i/$($targets.Count)" $pct
    Stamp "[winget] Uninstalling: $($t.Name)"
    if ($WhatIf) {
      Stamp "[winget] (WhatIf) winget uninstall --exact --name '$($t.Name)' --source msstore --silent --accept-package-agreements --accept-source-agreements"
      continue
    }
    $wingetArgs = @('uninstall','--exact','--name',"$($t.Name)",'--source','msstore','--silent','--accept-package-agreements','--accept-source-agreements')
    try {
      & winget @wingetArgs | ForEach-Object { Stamp "[winget] $_" }
    } catch {
      Stamp "[winget] Failed: $($t.Name) :: $($_.Exception.Message)"
    }
  }
  if ($IsInteractive) { Write-Progress -Activity "Removing MS 365/OneNote language packs (winget)" -Completed }
  return $targets
}

# --- Appx fallback (Office + OneNote) ----------------------------------------
function Remove-WithAppx {
  param([string]$KeepLang, [switch]$WhatIf)

  # Remove *resource* packages related to Office or OneNote that are not en-us
  $cands = Get-AppxPackage -AllUsers | Where-Object {
    $_.IsResourcePackage -and
    ($_.Name -match '(Office|Microsoft365|Microsoft\.Office|OneNote|Microsoft\.OneNote)') -and
    ($_.Name -notmatch '(?i)en[-_]?us')
  }

  if (-not $cands) { return @() }

  Stamp "[appx] Total items pending removal: $($cands.Count)"

  $i = 0
  foreach ($pkg in $cands) {
    $i++
    $remaining = $cands.Count - $i + 1
    Stamp "[appx] Remaining: $remaining of $($cands.Count)"
    $pct = [int](($i / $cands.Count) * 100)
    Show-Progress "Removing Appx resource packages (Office/OneNote)" "$($pkg.Name) $i/$($cands.Count)" $pct
    if ($WhatIf) {
      Stamp "[appx] (WhatIf) Remove-AppxPackage -Package '$($pkg.PackageFullName)' -AllUsers"
      continue
    }
    try {
      Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
      Stamp "[appx] Removed: $($pkg.Name)"
    } catch {
      Stamp "[appx] Failed: $($pkg.Name) :: $($_.Exception.Message)"
    }
  }
  if ($IsInteractive) { Write-Progress -Activity "Removing Appx resource packages (Office/OneNote)" -Completed }
  return $cands | Select-Object -Property Name
}

# --- Run ----------------------------------------------------------------------
Stamp "Start language cleanup. Keeping: $Keep"
$appxRemoved   = @()
$wingetRemoved = @()

# Run Appx fallback if winget found nothing (or belt-and-suspenders)
if (-not $wingetRemoved) {
  $appxRemoved = Remove-WithAppx -KeepLang $Keep -WhatIf:$WhatIf
}

# If ARP still shows Click-to-Run language components, use ODT to remove them
$arpLangs = Get-InstalledC2RLanguages | Where-Object { $_ -ne $Keep.ToLower() }
# If languages still present, skip winget/Appx and go to verification
$odtNeedsRetry = $false
if ($arpLangs.Count -gt 0) {
  Stamp "[odt] Detected Click-to-Run language components still present: $($arpLangs -join ', ')"
  Remove-WithODT -KeepLang $Keep -WhatIf:$WhatIf
}

# Recompute ARP detection after ODT
$arpLangs = Get-InstalledC2RLanguages | Where-Object { $_ -ne $Keep.ToLower() }
# If languages still present, skip winget/Appx and go to verification
$odtNeedsRetry = $false
if ($arpLangs.Count -gt 0) {
  Stamp "[odt] Languages still present after ODT step; skipping winget/Appx cleanup."
  $odtNeedsRetry = $true
}

if (-not $odtNeedsRetry) {
  # Next: Winget removal...
  $wingetRemoved = Remove-WithWinget -KeepLang $Keep -NamePatterns $wingetPrefixes -WhatIf:$WhatIf

  # Appx fallback only if winget found nothing (historical resource packs)
  if (-not $wingetRemoved) {
    $appxRemoved = Remove-WithAppx -KeepLang $Keep -WhatIf:$WhatIf
  }
}

# --- Post-run verification (helpful in RMM logs) ------------------------------
# Look again for any leftover MS365/OneNote language entries
$remainingWinget = @()
try {
  $rows = winget list --source msstore 2>$null
  foreach ($pattern in $wingetPrefixes) {
    $remainingWinget += ($rows | Select-String -Pattern $pattern | ForEach-Object { $_.Line })
  }
} catch { }

$remainingAppx = Get-AppxPackage -AllUsers | Where-Object {
  $_.IsResourcePackage -and
  ($_.Name -match '(Office|Microsoft365|Microsoft\.Office|OneNote|Microsoft\.OneNote)') -and
  ($_.Name -notmatch '(?i)en[-_]?us')
} | Select-Object -ExpandProperty Name

$remainingC2R = Get-InstalledC2RLanguages | Where-Object { $_ -ne $Keep.ToLower() }

Stamp "Summary: removed via winget = $($wingetRemoved.Count), via appx = $($appxRemoved.Count)"
if ($remainingWinget.Count -eq 0 -and $remainingAppx.Count -eq 0 -and $remainingC2R.Count -eq 0) {
  Stamp "Remaining language packs (MS365/OneNote): none"
} else {
  if ($remainingWinget) {
    Stamp "Remaining winget MS Store entries:"
    $remainingWinget | ForEach-Object { Stamp "  $_" }
  }
  if ($remainingAppx) {
    Stamp "Remaining Appx resource packages:"
    $remainingAppx | ForEach-Object { Stamp "  $_" }
  }
  if ($remainingC2R) {
    Stamp "Remaining Click-to-Run languages (by detection):"
    $remainingC2R | ForEach-Object { Stamp "  $_" }
  }
}

Stamp "Completed."
exit 0