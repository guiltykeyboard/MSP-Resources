# Deploy-DNSFilterAgent

[![Platform](https://img.shields.io/badge/Platform-Windows-black?logo=windows)](../../Scripts/Windows/Deploy-DNSFilterAgent.ps1)
[![Language](https://img.shields.io/badge/Language-PowerShell%205.1-0078d4?logo=powershell&logoColor=white)](../../Scripts/Windows/Deploy-DNSFilterAgent.ps1)
[![RMM](https://img.shields.io/badge/RMM-ConnectWise%20RMM%20(Asio)-00a2e1)](../../Scripts/Windows/Deploy-DNSFilterAgent.ps1)

## Synopsis

Installs the DNSFilter Windows agent from a ConnectWise RMM task: picks the
x64 or ARM64 MSI from the endpoint's real OS architecture, downloads it into
`$env:TEMP`, **verifies it against the vendor's published SHA256**, installs it
with the site's secret key, and deletes the installer afterwards. The site key
comes from a site-level custom field through the `@DNSFilter-Site-Token@`
placeholder.

Run as **SYSTEM**. No interactive input, no `C:\temp` folder, nothing left behind.

Companion script: [`Uninstall-DNSFilterAgent.ps1`](../Uninstall-DNSFilterAgent/README.md)
for manual removal when the dashboard cannot do it.

## Why this script exists

DNSFilter publishes two Windows packages, and the vendor's sample snippet assumes
`C:\temp` exists and that you have already decided which one to use:

```bat
msiexec /qn /i "DNSFilter-Agent-Setup-x64.msi"   NKEY="SITESECRETKEY"
msiexec /qn /i "DNSFilter-Agent-Setup-arm64.msi" NKEY="SITESECRETKEY"
```

Three things break in real fleets:

1. **Architecture is not `$env:PROCESSOR_ARCHITECTURE`.** A 32-bit PowerShell host
   on Windows 11 ARM64 reports `x86`, so a naive check installs the x64 package on
   an ARM device, where it only runs under emulation. This script checks
   `PROCESSOR_ARCHITEW6432`, then `RuntimeInformation.OSArchitecture`, then
   `Win32_Processor.Architecture` (12 = ARM64, 9 = x64), and stops rather than
   guessing.
2. **The key is per site.** Hard-coding `SITESECRETKEY` per client means one script
   per customer. Here the key comes from a site-level custom field, so there is one
   RMM task for every site.
3. **Installers pile up.** Writing to `$env:TEMP` in a GUID subfolder and removing
   that folder in a `finally` block means the MSI and the msiexec log are gone
   whether the install succeeded or failed. The msiexec log is copied to
   `%ProgramData%\iTech\Logs` first, so failures are still diagnosable.

## Integrity: the published checksum

Each unversioned installer has a matching checksum document - the installer name
plus `.sha256sum.asc`, for example
`DNSFilter-Agent-Setup-x64.msi.sha256sum.asc`. Before anything is installed the
script downloads that document into the same `$env:TEMP` staging folder, extracts
the SHA256, and compares it with the file it just downloaded:

```text
[OK] Checksum verified against the published SHA256: 9F2C...
```

On a mismatch the installer is deleted and the run stops with exit **2** and
`status: checksum-mismatch` - nothing is handed to `msiexec`.

The parser reads the document **by shape, not by line position**, because these
files are usually PGP-armoured and the hash line format varies:

| Document form | Example |
|---|---|
| `sha256sum` | `<hash>  DNSFilter-Agent-Setup-x64.msi` |
| binary mode | `<hash> *DNSFilter-Agent-Setup-x64.msi` |
| BSD / openssl | `SHA256 (DNSFilter-Agent-Setup-x64.msi) = <hash>` |

A candidate hash must be exactly 64 hex characters, so a filename or the word
`SHA256` can never be mistaken for the value. Junk documents produce no hash and
are reported as unavailable rather than compared against nonsense.

> **This is integrity, not authenticity.** The script compares hashes; it does not
> verify the PGP signature on the `.asc`. A tampered checksum file served alongside
> a tampered installer would pass. Treat it as corruption and transport detection.

### Is there a new build?

Because the staging folder is purged every run, there is nothing persistent to
compare against - so the script records the verified hash per architecture at
`%ProgramData%\iTech\Logs\DNSFilter-agent-<arch>.build` and reports
`buildChanged: true|false` in the JSON. That gives you the "did the vendor ship a
new build" signal without keeping installers on disk.

### When the checksum cannot be read

`-ChecksumVerification` decides what that means:

| Value | Behaviour |
|---|---|
| `Auto` (default) | Verify when the document is readable; **warn** and continue with the MSI signature check only when it is not. |
| `Require` | Unreadable checksum is fatal: installer deleted, exit 2, `status: checksum-unavailable`. |
| `Skip` | No checksum at all. Logged as a warning so the run is never silently unverified. |

A pinned build (`-AgentVersion 3.6.10`) may not have a sidecar document; `Auto`
handles that with a warning, `Require` would refuse it - choose per task.

## Before you deploy

1. **Create the site-level custom field** `DNSFilter-Site-Token` on each site and
   set its value to that site's secret key from DNSFilter (**Sites > your site >
   Site Secret Key**).
2. **Map it on the task.** The script parameter `SiteToken` defaults to the literal
   `@DNSFilter-Site-Token@`, which RMM substitutes when the field exists. Nothing
   else to wire up.
3. **Run as SYSTEM** with a 64-bit PowerShell host where possible. A 32-bit host
   still works - detection and the registry scan both handle it - but 64-bit is the
   cleaner signal.
4. **Allow the download path** if you filter egress: `downloads.dnsfilter.com` over
   HTTPS/443. A content filter that returns an HTML block page is caught by the MSI
   signature check and by the checksum step, instead of failing later inside Windows
   Installer.

If the field is missing or empty the task exits **2** with a message naming the
placeholder, so the RMM run shows red instead of installing an agent that binds to
no site.

## Usage

```powershell
# Normal RMM payload - architecture, checksum and key all resolved automatically
.\Deploy-DNSFilterAgent.ps1

# Pilot one endpoint, pinned build, change nothing
.\Deploy-DNSFilterAgent.ps1 -SiteToken 'yoursitekey' -AgentVersion '3.6.10' -TestOnly

# Refuse to install unless the published checksum was verified
.\Deploy-DNSFilterAgent.ps1 -ChecksumVerification Require

# Repair or re-key an agent installed with the wrong site key
.\Deploy-DNSFilterAgent.ps1 -SiteToken 'yoursitekey' -Force

# Remove the agent (detects modern and legacy whitelabel builds)
.\Deploy-DNSFilterAgent.ps1 -Uninstall

# Pre-flight an uninstall: reports what would be removed, changes nothing
.\Deploy-DNSFilterAgent.ps1 -Uninstall -TestOnly
```

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-SiteToken` | `@DNSFilter-Site-Token@` | Site secret key. Substituted by RMM from the site field; falls back to `$env:DNSFilter_Site_Token`. |
| `-Architecture` | `Auto` | `Auto`, `x64` or `arm64`. Override only when detection is wrong for a device. |
| `-AgentVersion` | *(empty)* | Pin a build, e.g. `3.6.10` -> `DNSFilter-Agent-Setup-x64-3.6.10.msi`. Empty uses the evergreen unversioned package. |
| `-BaseUrl` | `https://downloads.dnsfilter.com/User_Agent/Windows` | Download root, for a mirror or a test build. |
| `-Force` | off | Repair/re-key an existing agent (`REINSTALL=ALL REINSTALLMODE=vomus`). |
| `-Uninstall` | off | Remove by ARP product code. No key required; combined with `-TestOnly` it reports only. |
| `-TestOnly` | off | Report architecture, package URL, token state and current state; download, install and uninstall nothing. Checked before every mutating path. |
| `-ProbeLocalResolver` | off | Resolve `dnsfilter.com` against `127.0.0.1` after install. Informational, never changes the exit code. |
| `-ChecksumVerification` | `Auto` | `Auto`, `Require` or `Skip` - see the integrity section. |
| `-LogPath` | `%ProgramData%\iTech\Logs\DNSFilter-Agent-<host>.log` | Transcript log. |
| `-DownloadRetries` | `3` | Attempts before giving up, with backoff between them. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Installed, already present, uninstalled, or pre-flight OK |
| `1` | Install, uninstall or verification failed - read the log |
| `2` | Parameter or prerequisite problem: missing/invalid site key, unknown architecture, 32-bit-only OS, download failure, invalid package, **checksum mismatch**, **checksum unavailable while `Require`d** |

The JSON summary and the exit code are emitted at a single point after the
implementation returns, so every completion path - pre-flight, uninstall,
already-installed, download failure, checksum failure, install failure,
verification failure - reports and exits the same way. A failed run cannot look
green in RMM.

## States reported in the JSON summary

`install`, `repair`, `skip`, `uninstall`, `preflight` are the actions. `status` is
one of: `installed`, `installed-reboot`, `already-installed`, `uninstalled`,
`uninstall-failed`, `not-installed`, `preflight-ok`, `missing-token`,
`invalid-token`, `architecture-unknown`, `unsupported-os`, `download-failed`,
`invalid-package`, `checksum-mismatch`, `checksum-unavailable`, `installed-unverified`,
`failed`, `error`.

`checksumStatus` is `verified`, `unavailable`, `mismatch`, `skipped` or
`not-checked`, alongside `checksumExpected`, `checksumActual` and `buildChanged`.

```json
{"script":"Deploy-DNSFilterAgent","commit":"unstamped","computer":"WS-042","when":"2026-11-25T14:02:11.4421-05:00","action":"install","architecture":"arm64","package":"https://downloads.dnsfilter.com/User_Agent/Windows/DNSFilter-Agent-Setup-arm64.msi","tokenState":"parameter","status":"installed","msiExit":0,"product":"DNSFilter Agent","version":"3.6.10","service":"DNSFilter Agent (Running)","resolverProbe":null,"checksumStatus":"verified","checksumExpected":"9F2C...","checksumActual":"9F2C...","buildChanged":true,"exitCode":0,"detail":"Success"}
```

## How it runs

1. Refuses a 32-bit-only OS; resolves x64 vs ARM64.
2. Resolves the site key (parameter, then environment), validates its shape, and
   logs only a masked hint (`abcd...yz`). `-Uninstall` does not need it, so an
   uninstall pre-flight is never blocked by an empty field.
3. Builds the package URL; reads Add/Remove Programs for an existing agent through
   **both** registry views (`Registry64` then `Registry32`), so a 32-bit PowerShell
   host still sees a native x64/ARM64 install.
4. **`-TestOnly` stops here** - before either mutating path.
5. `-Uninstall` removes by product code (`msiexec /x`) and exits.
6. An existing agent without `-Force` exits 0 as `already-installed`.
7. Creates `%TEMP%\DNSFilterAgent_<8 hex>`, downloads with TLS 1.2 and retries,
   and checks the OLE compound-file signature (an HTML block page is not an MSI).
8. Downloads the `.sha256sum.asc`, parses the published SHA256, and compares it with
   `Get-FileHash` of the download. Mismatch = delete + exit 2. Records the hash for
   the next run's `buildChanged`.
9. `msiexec /i "<msi>" /qn /norestart /l*v "<log>" NKEY="<key>"`, exit codes mapped
   (`3010`/`1641` treated as success-with-reboot, `1603`/`1618`/`1625`/`1633`/`1638`/
   `1639` each explained in the log).
10. Verifies the product in Add/Remove Programs or the agent service is present - if
    msiexec said success but neither exists, it exits 1 rather than reporting green.
11. `finally`: copy the msiexec log to the logs folder, delete the staging folder.
12. Emit the JSON summary and exit with the recorded code.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `status: checksum-mismatch`, exit 2 | The download did not match the published hash - corrupted transfer or a proxy rewriting content. Re-run; if it repeats, check the egress path. Nothing was installed. |
| `status: checksum-unavailable` with `Require` | The `.sha256sum.asc` could not be fetched or parsed. Confirm the pinned build actually publishes one, or drop to `Auto`. |
| `checksumStatus: unavailable` (warning only) | `Auto` with no readable checksum. The MSI signature check still passed, but integrity is unconfirmed. |
| `status: missing-token`, exit 2 | Site field `DNSFilter-Site-Token` is empty or not mapped on the task. Fill the field, re-run. |
| `status: invalid-token`, exit 2 | Key contains quotes, spaces or slashes. Re-copy it from DNSFilter. |
| `status: invalid-package`, exit 2 | Something in the path returned HTML instead of an MSI - check egress filtering to `downloads.dnsfilter.com`. |
| msiexec `1603` | Generic failure: read `DNSFilter-msiexec-<host>.log` in the logs folder. Often an existing install or a policy block. |
| msiexec `1638` | A different agent version is already installed - re-run with `-Force`. |
| msiexec `1625` | Blocked by AppLocker or Software Restriction Policies. |
| `installed-unverified`, exit 1 | msiexec returned success but no product or service appeared. The install did not take; check the log. |
| Agent installed with the wrong site key | `-Force` with the correct `-SiteToken` to re-key. |

## Notes

- Detects both the modern **DNSFilter Agent** and the legacy whitelabel
  **DNS Agent** in Add/Remove Programs, and matches the service by binary path
  because service names differ between builds.
- Add/Remove Programs is read with `Microsoft.Win32.RegistryKey::OpenBaseKey` for
  `Registry64` and `Registry32` rather than the `HKLM:\SOFTWARE` provider path,
  which a 32-bit host redirects to `WOW6432Node`.
- The msiexec log is kept at `%ProgramData%\iTech\Logs\DNSFilter-msiexec-<host>.log`;
  change `-LogPath` if you keep RMM logs elsewhere.
- `-AgentVersion` pins a build for change control; leave it empty to always take
  the current package.
- Exit codes follow the same convention as the other Windows scripts here:
  `0` ok, `1` failed, `2` parameter/prerequisite.

## Script

- `ConnectWise-RMM-Asio/Scripts/Windows/Deploy-DNSFilterAgent.ps1`

## Vendor references

- Windows Roaming Client deployment: <https://help.dnsfilter.com/hc/en-us/articles/1500008104822-Windows-Roaming-Client-Deployment-Guide>
- Silent / remote-tool install, including the published checksum files: <https://help.dnsfilter.com/hc/en-us/articles/31177309034899-Windows-Roaming-Client-Silent-Remote-tool-Install>
