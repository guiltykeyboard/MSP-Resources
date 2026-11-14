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

    Child streams are separated rather than merged. On Windows PowerShell 5.1 a
    native command's stderr becomes an ErrorRecord when redirected with 2>&1,
    and $ErrorActionPreference = 'Stop' turns the first of those into a
    terminating error - which would push every payload failure into the
    CHILD_START_FAILED path and throw away its reason. So stderr is redirected
    to a file and the preference is relaxed for the call itself.

    Why the SHA: fetching /main/ can be served stale by the GitHub CDN, and
    fetching by branch with a cache-buster is the problem the old self-updater
    was invented to patch. Content at a commit SHA is immutable, so a stale copy
    is structurally impossible. The resolved SHA is cached per repository so a
    fleet behind one egress IP does not exhaust GitHub's unauthenticated API
    limit; when resolution fails the wrapper falls back to the branch name and
    BL_REF shows that it did.

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
    Version: 2.2.0

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

        The cache entry is keyed on the repository: two repositories on one
        endpoint would otherwise reuse each other's SHA inside the window, and
        the second download would 404 against a commit that does not exist there.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$CacheMinutes
    )

    $cacheDir  = Join-Path $env:ProgramData 'iTech\RMM'
    $cacheKey  = ($Repo -replace '[^A-Za-z0-9._-]', '_')
    $cacheFile = Join-Path $cacheDir ('bitlocker-check-ref_{0}.txt' -f $cacheKey)
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
                Set-Content -LiteralPath $cacheFile -Value ('{0}|{1}|{2}' -f $now, $sha, $Repo) -Encoding ASCII -ErrorAction Stop
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

$url     = 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $Repo, $ref, $RelPath
$tmp     = Join-Path $env:TEMP ('chkbl_{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
$errFile = Join-Path $env:TEMP ('chkbl_{0}.err' -f ([guid]::NewGuid().ToString('N')))

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
# stderr goes to its own file, and the preference is relaxed for the call: on
# PowerShell 5.1 a redirected native stderr would otherwise raise a terminating
# error under 'Stop' and every payload reason would be lost.
$stdoutOut = @()
$stderrOut = @()
$code      = -1
$launch    = $null
$prevEap   = $ErrorActionPreference

try {
    $ErrorActionPreference = 'Continue'
    $stdoutOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -NoElevate -SelfUpdated 2> $errFile
    $code      = $LASTEXITCODE
}
catch {
    $launch = $_.Exception.Message
}
finally {
    $ErrorActionPreference = $prevEap
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $errFile) {
    try { $stderrOut = @(Get-Content -LiteralPath $errFile -ErrorAction Stop) }
    catch { $stderrOut = @() }
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
}

if ($launch) {
    Write-Failure -Reason 'CHILD_START_FAILED' -Detail $launch -Ref $ref -Url $url
}

if (-not $stdoutOut -and -not $stderrOut) {
    Write-Failure -Reason 'CHILD_START_FAILED' `
        -Detail 'the nested request produced no output on stdout or stderr' `
        -Ref $ref -Url $url
}

# --- interpret ---------------------------------------------------------------
# A verdict is a clean 0 or 1 on stdout from a child that exited 0. There is
# deliberately no "take the last line" fallback: that is what turned log prose
# into a Yes. Reasons are read from stderr, where the payload writes them.
$val         = $null
$childReason = $null
$childDetail = $null

foreach ($line in $stderrOut) {
    $text = $line.ToString().Trim()

    if ($text -match '^BL_REASON=(.+)$') { $childReason = $Matches[1]; continue }
    if ($text -match '^BL_DETAIL=(.+)$') { $childDetail = $Matches[1]; continue }
}

foreach ($line in $stdoutOut) {
    $text = $line.ToString().Trim()
    if ($text -eq '0' -or $text -eq '1') { $val = $text }
}

if ($code -ne 0) {
    $reason = if ($childReason) { $childReason } else { 'CHILD_EXIT_{0}' -f $code }
    $detail = if ($childDetail) { $childDetail } else { 'nested request exited {0} without a reason line' -f $code }
    Write-Failure -Reason $reason -Detail $detail -Ref $ref -Url $url
}

if ($null -eq $val) {
    Write-Failure -Reason 'NO_DIGIT_IN_OUTPUT' `
        -Detail 'nested request exited 0 but printed neither 0 nor 1 on stdout' `
        -Ref $ref -Url $url
}

Write-Output $val
exit 0
