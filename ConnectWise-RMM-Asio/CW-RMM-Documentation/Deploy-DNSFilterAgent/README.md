# Deploy-DNSFilterAgent

[![Platform](https://img.shields.io/badge/Platform-Windows-black?logo=windows)](../../Scripts/Windows/Deploy-DNSFilterAgent.ps1)
[![Language](https://img.shields.io/badge/Language-PowerShell%205.1-0078d4?logo=powershell&logoColor=white)](../../Scripts/Windows/Deploy-DNSFilterAgent.ps1)
[![RMM](https://img.shields.io/badge/RMM-ConnectWise%20RMM%20(Asio)-00a2e1)](../../Scripts/Windows/Deploy-DNSFilterAgent.ps1)

## Synopsis

Installs the DNSFilter Windows agent from a ConnectWise RMM task: picks the
x64 or ARM64 MSI from the endpoint's real OS architecture, downloads it into
`$env:TEMP`, installs it with the site's secret key, and deletes the installer
afterwards. The site key comes from a site-level custom field through the
`@DNSFilter-Site-Token@` placeholder.

Run as **SYSTEM**. No interactive input, no `C:\temp` folder, nothing left behind.

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

## Before you deploy

1. **Create the site-level custom field** `DNSFilter-Site-Token` on each site and
   set its value to that site's secret key from DNSFilter (**Sites > your site >
   Site Secret Key**).
2. **Map it on the task.** The script parameter `SiteToken` defaults to the literal
   `@DNSFilter-Site-Token@`, which RMM substitutes when the field exists. Nothing
   else to wire up.
3. **Run as SYSTEM** with a 64-bit PowerShell host where possible. A 32-bit host
   still works - detection handles it - but 64-bit is the cleaner signal.
4. **Allow the download path** if you filter egress: `downloads.dnsfilter.com` over
   HTTPS/443. A content filter that returns an HTML block page is caught by the MSI
   signature check instead of failing later inside Windows Installer.

If the field is missing or empty the task exits **2** with a message naming the
placeholder, so the RMM run shows red instead of installing an agent that binds to
no site.

## Usage

```powershell
# Normal RMM payload - architecture and key both resolved automatically
.\Deploy-DNSFilterAgent.ps1

# Pilot one endpoint, pinned build, change nothing
.\Deploy-DNSFilterAgent.ps1 -SiteToken 'yoursitekey' -AgentVersion '3.6.10' -TestOnly

# Repair or re-key an agent installed with the wrong site key
.\Deploy-DNSFilterAgent.ps1 -SiteToken 'yoursitekey' -Force

# Remove the agent (detects modern and legacy whitelabel builds)
.\Deploy-DNSFilterAgent.ps1 -Uninstall

# Verify the agent answers as a local resolver after install
.\Deploy-DNSFilterAgent.ps1 -ProbeLocalResolver
```

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-SiteToken` | `@DNSFilter-Site-Token@` | Site secret key. Substituted by RMM from the site field; falls back to `$env:DNSFilter_Site_Token`. |
| `-Architecture` | `Auto` | `Auto`, `x64` or `arm64`. Override only when detection is wrong for a device. |
| `-AgentVersion` | *(empty)* | Pin a build, e.g. `3.6.10` -> `DNSFilter-Agent-Setup-x64-3.6.10.msi`. Empty uses the evergreen unversioned package. |
| `-BaseUrl` | `https://downloads.dnsfilter.com/User_Agent/Windows` | Download root, for a mirror or a test build. |
| `-Force` | off | Repair/re-key an existing agent (`REINSTALL=ALL REINSTALLMODE=vomus`). |
| `-Uninstall` | off | Remove by ARP product code. No key required. |
| `-TestOnly` | off | Report architecture, package URL and current state; download and install nothing. |
| `-ProbeLocalResolver` | off | Resolve `dnsfilter.com` against `127.0.0.1` after install. Informational, never changes the exit code. |
| `-LogPath` | `%ProgramData%\iTech\Logs\DNSFilter-Agent-<host>.log` | Transcript log. |
| `-DownloadRetries` | `3` | Attempts before giving up, with backoff between them. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Installed, already present, uninstalled, or pre-flight OK |
| `1` | Install or verification failed - read the log |
| `2` | Parameter or prerequisite problem: missing/invalid site key, unknown architecture, 32-bit-only OS, download failure, invalid package |

## States reported in the JSON summary

`install`, `repair`, `skip`, `uninstall`, `preflight` are the actions. `status` is
one of: `installed`, `installed-reboot`, `already-installed`, `uninstalled`,
`not-installed`, `preflight-ok`, `missing-token`, `invalid-token`,
`architecture-unknown`, `unsupported-os`, `download-failed`, `invalid-package`,
`installed-unverified`, `failed`, `error`.

```json
{"script":"Deploy-DNSFilterAgent","commit":"unstamped","computer":"WS-042","when":"2026-11-25T14:02:11.4421-05:00","action":"install","architecture":"arm64","package":"https://downloads.dnsfilter.com/User_Agent/Windows/DNSFilter-Agent-Setup-arm64.msi","tokenState":"parameter","status":"installed","msiExit":0,"product":"DNSFilter Agent","version":"3.6.10","service":"DNSFilter Agent (Running)","resolverProbe":null,"exitCode":0,"detail":"Success"}
```

## How it runs

1. Refuses a 32-bit-only OS; resolves x64 vs ARM64.
2. Resolves the site key (parameter, then environment), validates its shape, and
   logs only a masked hint (`abcd...yz`).
3. Builds the package URL; reports any existing agent found in Add/Remove Programs.
4. `-Uninstall` removes it and exits. `-TestOnly` stops here. An existing agent
   without `-Force` exits 0 as `already-installed`.
5. Creates `%TEMP%\DNSFilterAgent_<8 hex>`, downloads with TLS 1.2 and retries,
   verifies the OLE compound-file signature (an HTML block page is not an MSI),
   logs the SHA256.
6. `msiexec /i "<msi>" /qn /norestart /l*v "<log>" NKEY="<key>"`, exit codes mapped
   (`3010`/`1641` treated as success-with-reboot, `1603`/`1618`/`1625`/`1633`/`1638`/
   `1639` each explained in the log).
7. Verifies the product in Add/Remove Programs or the agent service is present - if
   msiexec said success but neither exists, it exits 1 rather than reporting green.
8. `finally`: copy the msiexec log to the logs folder, delete the staging folder.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
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
- Silent / remote-tool install (x64 and ARM64 packages): <https://help.dnsfilter.com/hc/en-us/articles/31177309034899-Windows-Roaming-Client-Silent-Remote-tool-Install>
