#Requires -Version 5.1
<#
.SYNOPSIS
    CW RMM step: report whether BitLocker is enabled as exactly one line, 1 or 0
    - and when there is no answer, say why in the script log.

.DESCRIPTION
    Fetches checkIfBitlockerEnabled.ps1 at an immutable commit SHA, runs it in a
    child process so its exit code cannot escape into this script, and prints a
    single line to stdout on success.

    When there is no verdict it prints no digit at all. Instead it writes BL_*
    lines, which the RMM step output carries into the script log:

        BL_STATUS=NO_VERDICT
        BL_REASON=DOWNLOAD_FAILED
        BL_DETAIL=The remote server returned an error: (404) Not Found.
        BL_REF=a5dec8d6329d7146b724673e6c52fa2f2237a274
        BL_URL=https://raw.githubusercontent.com/...

    No BL_ line can match the branch conditions (^\s*1\s*$ and ^\s*0\s*$), so a
    failed run lands in the log-only branch and cannot touch the custom field.
    The point is that "we could not tell" is never silent: the reason, the ref
    that was requested, and the URL are all in the log.

    Why the SHA: fetching /main/ can be served stale by the GitHub CDN, and
    fetching by branch with a cache-buster is the problem the old self-updater
    was invented to patch. Content at a commit SHA is immutable, so a stale copy
    is structurally impossible. The resolved SHA is cached locally for a few
    minutes so a fleet behind one egress IP does not exhaust GitHub's
    unauthenticated API limit; when resolution fails the wrapper falls back to
    the branch name and BL_REF shows that it did.

    Why -SelfUpdated on the child: it suppresses the legacy self-updater in the
    v1 payload, so this wrapper is safe to deploy BEFORE the new payload lands.

.PARAMETER Repo
    owner/name of the repository holding the payload.

.PARAMETER RelPath
    Path to the payload inside the repository.

.PARAMETER ShaCacheMinutes
    How long a resolved commit SHA may be reused on this host. 0 disables cache.

.PARAMETER TimeoutSec
    Timeout for the metadata call and the payload download.

.OUTPUTS
    Success: System.String - '1' or '0', one line.
    Failure: BL_STATUS / BL_REASON / BL_DETAIL / BL_REF / BL_URL lines, no digit.

.NOTES
    Exit codes:
      0  verdict emitted on stdout
      1  no verdict - the BL_ lines say why
    Version: 2.1.0

    Reasons raised here:
      DOWNLOAD_HTTP_404       path or ref not found at the remote
      DOWNLOAD_HTTP_403       access denied, or API rate limit hit
      DOWNLOAD_RATE_LIMITED   HTTP 429
      DOWNLOAD_SERVER_ERROR   HTTP 5xx
      DNS_FAILURE             host could not be resolved or reached
      TIMEOUT                 no answer within TimeoutSec
      PROXY_BLOCKED           proxy refused the request
      TLS_FAILURE             TLS negotiation or certificate failure
      DOWNLOAD_FAILED         any other transport error
      CHILD_START_FAILED      the child process could not be started
      CHILD_EXIT_<n>          the payload exited <n> without explaining why
      NO_DIGIT_IN_OUTPUT      the payload exited 0 but printed no 0 or 1
    Reasons relayed from the payload: NO_BITLOCKER_CMDLETS, NO_DRIVES,
    SYSTEM_VOLUME_UNKNOWN, ALL_DRIVES_UNKNOWN, UNEXPECTED.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'guiltykeyboard/MSP-Resources',
    [string]$RelPath = 'ConnectWise-RMM-Asio/Scripts/Windows/checkIfBitlockerEnabled.ps1',
    [int]$ShaCacheMinutes = 15,
    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Failure {
    <#
        Prints the reason block to stdout - which is where the RMM step output
        comes from, so it lands in the script log - and exits 1.

        None of these lines can match ^\s*[01]\s*$, so they cannot be mistaken
        for a verdict by the branch logic.
    #>
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string]$Detail,
        [string]$Ref,
        [string]$Url
    )

    Write-Output 'BL_STATUS=NO_VERDICT'
    Write-Output ('BL_REASON=' + $Reason)

    if ($Detail) {
        $clean = ($Detail -replace '[\r\n]+', ' ').Trim()
        if ($clean.Length -gt 300) { $clean = $clean.Substring(0, 300) + '...' }
        Write-Output ('BL_DETAIL=' + $clean)
    }
    if ($Ref) { Write-Output ('BL_REF=' + $Ref) }
    if ($Url) { Write-Output ('BL_URL=' + $Url) }

    exit 1
}

function Get-DownloadReason {
    <#
        Turns a transport exception into a stable reason code plus a readable
        detail, so the log says what kind of failure this was.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $ex     = $ErrorRecord.Exception
    $detail = ''
    if ($ex) { $detail = $ex.Message }

    $status = 0
    try {
        if ($ex -and ($ex.PSObject.Properties.Name -contains 'Response') -and $ex.Response) {
            $status = [int]$ex.Response.StatusCode
        }
    }
    catch { }

    switch ($status) {
        404 { return @{ Reason = 'DOWNLOAD_HTTP_404'; Detail = 'path or ref not found at the remote (404) - check RelPath, and that the branch still exists' } }
        403 { return @{ Reason = 'DOWNLOAD_HTTP_403'; Detail = 'access denied, or the unauthenticated API rate limit was hit (403)' } }
        429 { return @{ Reason = 'DOWNLOAD_RATE_LIMITED'; Detail = 'rate limited (429) - the SHA cache may be disabled or shared too widely' } }
        500 { return @{ Reason = 'DOWNLOAD_SERVER_ERROR'; Detail = $detail } }
        502 { return @{ Reason = 'DOWNLOAD_SERVER_ERROR'; Detail = $detail } }
        503 { return @{ Reason = 'DOWNLOAD_SERVER_ERROR'; Detail = $detail } }
    }

    if ($detail -match '(?i)name or service not known|could not be resolved|no such host|remote name could not be resolved') {
        return @{ Reason = 'DNS_FAILURE'; Detail = $detail }
    }
    if ($detail -match '(?i)timed out|timeout') {
        return @{ Reason = 'TIMEOUT'; Detail = $detail }
    }
    if ($detail -match '(?i)proxy|\(407\)') {
        return @{ Reason = 'PROXY_BLOCKED'; Detail = $detail }
    }
    if ($detail -match '(?i)\bSSL\b|\bTLS\b|certificate') {
        return @{ Reason = 'TLS_FAILURE'; Detail = $detail }
    }

    return @{ Reason = 'DOWNLOAD_FAILED'; Detail = $detail }
}

function Resolve-CommitRef {
    <#
        Resolve the branch tip to a commit SHA, caching it locally for a short
        while. Returns $null when it cannot be resolved; the caller then falls
        back to the branch name and the log shows that.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$CacheMinutes
    )

    $cacheDir  = Join-Path $env:ProgramData 'iTech\RMM'
    $cacheFile = Join-Path $cacheDir 'bitlocker-check-ref.txt'
    $now       = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if ($CacheMinutes -gt 0 -and (Test-Path -LiteralPath $cacheFile)) {
        try {
            $parts = (Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop).Trim() -split '\|'
            if ($parts.Count -eq 2 -and $parts[1].Trim().Length -ge 7) {
                $stamp = [long]0
                if ([long]::TryParse($parts[0], [ref]$stamp) -and ($now - $stamp) -lt ($CacheMinutes * 60)) {
                    return $parts[1].Trim()
                }
            }
        }
        catch { }
    }

    try {
        $uri = 'https://api.github.com/repos/{0}/commits/main' -f $Repo
        $sha = (Invoke-RestMethod -UseBasicParsing -TimeoutSec $TimeoutSec -Uri $uri `
                    -Headers @{ 'User-Agent' = 'CW-RMM' }).sha

        if ($sha -and $sha.Length -ge 7) {
            try {
                if (-not (Test-Path -LiteralPath $cacheDir)) {
                    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                }
                Set-Content -LiteralPath $cacheFile -Value ('{0}|{1}' -f $now, $sha) -Encoding ASCII -ErrorAction Stop
            }
            catch { }
            return $sha
        }
    }
    catch { }

    return $null
}

$ref = Resolve-CommitRef -Repo $Repo -CacheMinutes $ShaCacheMinutes
if (-not $ref) { $ref = 'main' }

$url = 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $Repo, $ref, $RelPath
$tmp = Join-Path $env:TEMP ('chkbl_{0}.ps1' -f ([guid]::NewGuid().ToString('N')))

# --- fetch -------------------------------------------------------------------
try {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp -TimeoutSec $TimeoutSec -ErrorAction Stop
}
catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $failure = Get-DownloadReason -ErrorRecord $_
    Write-Failure -Reason $failure.Reason -Detail $failure.Detail -Ref $ref -Url $url
}

# --- run ---------------------------------------------------------------------
$out  = @()
$code = -1

try {
    $out  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -NoElevate -SelfUpdated 2>&1
    $code = $LASTEXITCODE
}
catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Failure -Reason 'CHILD_START_FAILED' -Detail $_.Exception.Message -Ref $ref -Url $url
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

# --- interpret ---------------------------------------------------------------
# A verdict is a clean 0 or 1 from a child that exited 0. There is deliberately
# no "take the last line" fallback: that is what turned log prose into a Yes.
$val         = $null
$childReason = $null
$childDetail = $null

foreach ($line in $out) {
    $text = $line.ToString().Trim()

    if ($text -match '^BL_REASON=(.+)$') {
        $childReason = $Matches[1]
        continue
    }
    if ($text -match '^BL_DETAIL=(.+)$') {
        $childDetail = $Matches[1]
        continue
    }
    if ($text -eq '0' -or $text -eq '1') {
        $val = $text
    }
}

if ($code -ne 0) {
    $reason = if ($childReason) { $childReason } else { 'CHILD_EXIT_{0}' -f $code }
    $detail = if ($childDetail) { $childDetail } else { 'nested request exited {0} without a reason line' -f $code }
    Write-Failure -Reason $reason -Detail $detail -Ref $ref -Url $url
}

if ($null -eq $val) {
    Write-Failure -Reason 'NO_DIGIT_IN_OUTPUT' `
        -Detail 'nested request exited 0 but printed neither 0 nor 1' `
        -Ref $ref -Url $url
}

Write-Output $val
exit 0
