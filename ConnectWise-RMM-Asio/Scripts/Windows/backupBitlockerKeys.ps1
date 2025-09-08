[CmdletBinding()]
param(
  [switch]$NoElevate,
  [switch]$HumanReadable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RecoveryPasswordsFromManageBde {
  param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')] [string]$Drive)
  $present = Test-Path ("${Drive}:")
  if (-not $present) { return @() }
  try {
    $raw = & manage-bde -protectors -get "${Drive}:" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }

    $items = @()
    $current = $null
    $expectPwdNext = $false

    foreach ($line in $raw) {
      if ($line -match '^\s*ID:\s*\{([0-9A-Fa-f-]{36})\}') {
        $id = $Matches[1]
        $current = [ordered]@{ Id = "{$id}"; Password = $null }
        $expectPwdNext = $false
        continue
      }

      # Case 1: password value appears on the same line as the label
      if ($line -match '^\s*Password\s*:\s*([0-9\- ]{20,})\s*$') {
        if ($null -ne $current) {
          $RecoveryPwd = ($Matches[1] -replace '\s','').Trim()
          $current.Password = $RecoveryPwd
          $items += [pscustomobject]$current
          $current = $null
        }
        $expectPwdNext = $false
        continue
      }

      # Case 2: a bare label line; the next line should contain the digits
      if ($line -match '^\s*Password\s*:\s*$') {
        $expectPwdNext = $true
        continue
      }

      if ($expectPwdNext -and $line -match '^\s*([0-9\- ]{20,})\s*$') {
        if ($null -ne $current) {
          $RecoveryPwd = ($Matches[1] -replace '\s','').Trim()
          $current.Password = $RecoveryPwd
          $items += [pscustomobject]$current
          $current = $null
        }
        $expectPwdNext = $false
        continue
      }
    }

    return $items
  } catch { return @() }
}

function Add-RecoveryPasswordProtector {
  param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')] [string]$Drive)
  try {
    # Ensure diagnostics map exists in script scope (StrictMode-safe)
    if (-not (Get-Variable -Name 'AddRPDiag' -Scope Script -ErrorAction SilentlyContinue)) {
      Set-Variable -Name 'AddRPDiag' -Scope Script -Value @{}
    }
    # If a numerical/recovery password already exists, we're done
    $raw = & manage-bde -protectors -get "${Drive}:" 2>$null
    if ($raw -match 'Numerical\s*Password' -or $raw -match '^\s*Password\s*:' ) { return $true }

    # Add a recovery password protector (capture stderr/exit for diagnostics)
    $errText = (& manage-bde -protectors -add "${Drive}:" -rp 2>&1 | Out-String)
    $script:AddRPDiag["$Drive"] = @{ Exit = $LASTEXITCODE; Stderr = ($errText.Trim()) }
    if ($LASTEXITCODE -ne 0) { return $false }

    # Brief wait and re-check
    Start-Sleep -Seconds 2
    $raw2 = & manage-bde -protectors -get "${Drive}:" 2>$null
    return ($raw2 -match 'Numerical\s*Password' -or $raw2 -match '^\s*Password\s*:')
  } catch {
    return $false
  }
}

if (-not $script:AddRPDiag) { $script:AddRPDiag = @{} }

function Get-FixedDriveLetters {
  $letters = @()
  try {
    $letters = Get-Volume -ErrorAction Stop |
      Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
      ForEach-Object { $_.DriveLetter.ToString().ToUpper() }
  } catch {
    try {
      $letters = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object { $_.DeviceID -match ':' } |
        ForEach-Object { ($_.DeviceID.Substring(0,1)).ToString().ToUpper() }
    } catch {}
  }
  return @($letters | Sort-Object -Unique)
}

function Get-DeviceJoinState {
  $domainJoined = $false
  $azureAdJoined = $false
  try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $domainJoined = [bool]$cs.PartOfDomain
  } catch {}
  try {
    $ds = & dsregcmd.exe /status 2>$null
    if ($ds) { $azureAdJoined = ($ds -match "AzureAdJoined\s*:\s*YES") }
  } catch {}
  [pscustomobject]@{ DomainJoined = $domainJoined; AzureAdJoined = $azureAdJoined }
}

function Invoke-BackupToAD {
  param([Parameter(Mandatory)][string]$Drive, [Parameter(Mandatory)][string]$ProtectorId)
  try {
    $null = & manage-bde -protectors -adbackup "${Drive}:" -id $ProtectorId 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch { return $false }
}

function Invoke-BackupToAAD {
  param([Parameter(Mandatory)][string]$Drive, [Parameter(Mandatory)][string]$ProtectorId)
  $cmd = Get-Command BackupToAAD-BitLockerKeyProtector -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  try {
    BackupToAAD-BitLockerKeyProtector -MountPoint "${Drive}:" -KeyProtectorId $ProtectorId -ErrorAction Stop | Out-Null
    return $true
  } catch { return $false }
}

# --- main ---

function Test-IsElevated {
  try { return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
  catch { return $false }
}

if (-not $NoElevate -and -not (Test-IsElevated)) {
  try { Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoElevate" -Verb RunAs; exit 0 } catch {}
}

$errors = @()
try {
  $fixed = Get-FixedDriveLetters
  $join  = Get-DeviceJoinState

  $drivesOut = @{}
  $adAttempted = $false; $adSuccess = 0
  $aadAttempted = $false; $aadSuccess = 0

  foreach ($dl in $fixed) {
    $dl = $dl.ToString()
    $items = Get-RecoveryPasswordsFromManageBde -Drive $dl
    if ($null -eq $items -or (@($items).Count -eq 0)) {
      if (Add-RecoveryPasswordProtector -Drive $dl) {
        Start-Sleep -Seconds 2
        $items = Get-RecoveryPasswordsFromManageBde -Drive $dl
      } else {
        $diag = $script:AddRPDiag["$dl"]
        $code = if ($diag) { $diag.Exit } else { $null }
        $stderr = if ($diag) { $diag.Stderr } else { $null }
        $hint = $null
        if ($stderr -match '0x8031005A' -or $stderr -match 'FVE_E_POLICY_RECOVERY_PASSWORD_NOT_ALLOWED') { $hint = 'Policy blocks numerical recovery passwords (GPO/Intune). Enable numerical recovery or allow key escrow.' }
        elseif ($stderr -match '0x80310059' -or $stderr -match 'FVE_E_POLICY_USER_CONFIGURE_RECOVERY') { $hint = 'Policy forbids user-configured recovery. Configure recovery policy to allow creation/escrow.' }
        elseif ($stderr -match '0x80310054' -or $stderr -match 'FVE_E_LOCKED_VOLUME') { $hint = 'Volume locked/busy. Retry after reboot or ensure volume is accessible.' }
        $msg = "Add recovery password failed on $dl" + ($(if ($null -ne $code) { " (exit=$code)" } else { '' }))
        if ($hint) { $msg += ". Hint: $hint" }
        if ($stderr) { $msg += " STDERR: $stderr" }
        $errors += $msg
        $items = @()
      }
    }

    if ($null -eq $items) { $items = @() }
    $items = @($items)
    $drivesOut["$dl"] = [ordered]@{ HasKeys = [bool]($items.Count -gt 0); RecoveryPasswords = $items }

    foreach ($it in $items) {
      if ($join.DomainJoined) { $adAttempted = $true; if (Invoke-BackupToAD -Drive $dl -ProtectorId $it.Id) { $adSuccess++ } else { $errors += "AD escrow failed for $dl $($it.Id)" } }
      if ($join.AzureAdJoined) { $aadAttempted = $true; if (Invoke-BackupToAAD -Drive $dl -ProtectorId $it.Id) { $aadSuccess++ } else { $errors += "AAD escrow failed for $dl $($it.Id)" } }
    }
  }

  $keyCount = (
    $drivesOut.GetEnumerator() |
    ForEach-Object { @($_.Value.RecoveryPasswords).Count } |
    Measure-Object -Sum
  ).Sum
  if ($null -eq $keyCount) { $keyCount = 0 }

  $payload = [ordered]@{
    Device  = [ordered]@{ DomainJoined = [bool]$join.DomainJoined; AzureAdJoined = [bool]$join.AzureAdJoined }
    KeyCount = [int]$keyCount
    Drives  = $drivesOut
    Backups = [ordered]@{
      ActiveDirectory = [ordered]@{ Attempted = [bool]$adAttempted; Succeeded = [int]$adSuccess }
      AzureAD         = [ordered]@{ Attempted = [bool]$aadAttempted; Succeeded = [int]$aadSuccess }
    }
  }
  if ($errors.Count -gt 0) { $payload.Errors = @($errors) }

  $coreJson = $payload | ConvertTo-Json -Depth 6 -Compress
  $sha256 = [System.BitConverter]::ToString(( [System.Security.Cryptography.SHA256]::Create()).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($coreJson))).Replace('-', '').ToLowerInvariant()
  $chars = $coreJson.Length
  $payload._meta = [ordered]@{ sha256 = $sha256; chars = $chars }
  $finalJson = $payload | ConvertTo-Json -Depth 6 -Compress

  if ($HumanReadable) {
    "System Info:"; $payload.Device | Format-List | Out-String | Write-Output
    "Escrow Status:"; $payload.Backups | Format-List | Out-String | Write-Output
    "Drives:"; $payload.Drives.GetEnumerator() | ForEach-Object { $k = ($_.Key).ToString(); "Drive: {0}" -f $k; $_.Value | Format-List | Out-String | Write-Output }
  } else {
    Write-Output $finalJson
  }
}
catch {
  Write-Error ("BACKUPBITLOCKERKEYS ERROR: " + $_.Exception.Message)
  exit 1
}

exit 0
