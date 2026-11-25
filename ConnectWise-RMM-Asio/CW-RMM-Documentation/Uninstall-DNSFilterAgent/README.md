# Uninstall-DNSFilterAgent

[![Platform](https://img.shields.io/badge/Platform-Windows-black?logo=windows)](../../Scripts/Windows/Uninstall-DNSFilterAgent.ps1)
[![Language](https://img.shields.io/badge/Language-PowerShell%205.1-0078d4?logo=powershell&logoColor=white)](../../Scripts/Windows/Uninstall-DNSFilterAgent.ps1)
[![RMM](https://img.shields.io/badge/RMM-ConnectWise%20RMM%20(Asio)-00a2e1)](../../Scripts/Windows/Uninstall-DNSFilterAgent.ps1)

## Synopsis

Manual removal of the DNSFilter Windows agent (standard or legacy whitelabel) from
a ConnectWise RMM task, for the cases the dashboard cannot handle: versions older
than v2.0.1, agents stuck or offline, agents already deleted from the dashboard,
and machines carrying both the modern and the legacy client.

Companion script: [`Deploy-DNSFilterAgent.ps1`](../Deploy-DNSFilterAgent/README.md).
This one is a separate RMM task on purpose - removal is an explicit action, not a
mode of the deployment script.

## The version split is real

DNSFilter documents two different uninstall paths, and they are not interchangeable:

| | v2.0.1 and newer | v1.15.3 and older |
|---|---|---|
| Dashboard uninstall | works - **Delete & Uninstall**, agent picks it up on its next check-in (usually under 5 minutes) | **does not uninstall.** Deleting the client from the dashboard removes the record only; the agent stays on the endpoint |
| `REGCLEAN` property | supported by the MSI: `msiexec /X{GUID} REGCLEAN=true\|false` | not part of that path |
| Documented route | GUID from `HKLM\SOFTWARE\DNSFilter\Agent` or `HKLM\SOFTWARE\DNSAgent\Agent`, then `msiexec /X` | Add/Remove Programs, or `Get-WmiObject Win32_Product ... .UnInstall()` |
| Typical visibility | listed in Add/Remove Programs | often installed with `ARPSYSTEMCOMPONENT=1`, so **not** listed |

So the script detects the version per agent and picks the recipe:

- **modern** (`>= 2.0.1`) - `msiexec /X{code} /qn /norestart /l*vx! <log> REGCLEAN=true`
- **legacy** (`< 2.0.1`) - the same command without `REGCLEAN`, then a residue pass
- **unknown** - same as legacy (no `REGCLEAN`) and the log is kept for support

`-RegClean True` forces it on, `-RegClean:$false` forces it off. **With
`-RegClean:$false` the residue pass keeps the `SOFTWARE\DNSFilter` and
`SOFTWARE\DNSAgent` configuration trees**, so the script cannot contradict the MSI's
instruction to preserve the agent's registry state.

## Why Add/Remove Programs alone is not enough

An agent installed with `ARPSYSTEMCOMPONENT=1` keeps filtering but has no
Add/Remove Programs entry. A script that trusts that list reports "nothing
installed" and leaves the client running. Detection therefore unions four sources:

1. **Add/Remove Programs**, both registry views (`Registry64` and `Registry32`, so a
   32-bit PowerShell host still sees a native agent)
2. **`HKLM\SOFTWARE\DNSFilter\Agent`** and **`HKLM\SOFTWARE\DNSAgent\Agent`** - the
   GUID from the KB. The value name has changed between builds, so values and
   subkey names are scanned for the GUID shape rather than assuming a name
3. **The Windows Installer product database** via its COM API - independent of
   Add/Remove Programs, so it still lists a hidden product
4. **The service and install directory** (`DNSFilter Agent` / `DNS Agent`,
   `%ProgramFiles%\...` and `%ProgramData%\...`) - if either exists but nothing is
   registered, the two known DNSFilter product codes are tried

`Win32_Product` is **not** used, even though the older KB article suggests it.
Querying that class makes Windows Installer run a consistency check against every
installed product, which is slow and can kick off repairs on unrelated software.

## Residue cleanup runs once, per product

Every agent is removed first; the residue pass runs afterwards, once, over the
products that were **actually removed**. Services, directories and registry trees
are mapped per product, so clearing out a legacy `DNS Agent` can never delete the
modern `DNSFilter Agent`'s service or files.

Two deliberate limits:

- An agent that reports **1605 (product not registered)** changed nothing, so it
  does not authorise a residue pass - that is how an absent fallback candidate
  could otherwise delete a real agent that had not been attempted yet.
- Residue is **not** cleared for a product whose msiexec failed, unless you pass
  `-ForceCleanup`. A failed install is evidence; deleting it first is how you lose
  the reason it failed.

## Getting the MSI log into the RMM output

The KB's guidance is to re-run with `/L*vx!` to a local file and send it to support.
An RMM task cannot hand you a file, so the script always logs with `/L*vx!` to a
temporary path, then echoes a **digest** to STDOUT - error/`Return value 3` lines,
`Product:` lines, and the last `-LogTailLines` (default 40) lines - which lands in
the ConnectWise RMM script output. The full log is copied to
`%ProgramData%\iTech\Logs\DNSFilter-uninstall-<productcode>.log` as well.

`-FullMsiLog` dumps the entire log when support asks for it.

## DNS after removal

The agent points adapters at `127.0.0.1`. If a removal leaves that in place, the
endpoint has no working DNS - DNSFilter's own KB comments report exactly this after
a dashboard uninstall. After removal the script inspects every *up* adapter and,
for any that still list a loopback server:

- drops the loopback entries and keeps the real servers, or
- resets the adapter to DHCP when loopback was the only entry

Every change is logged with before/after values and reported in the JSON. A repair
that **fails** adds `dns-cleanup-failed` to the residue list and forces exit `1`,
because an endpoint still pointing at a dead loopback resolver is broken even
though the agent is gone.

Use `-DnsCleanup Report` to list the problem without changing anything.

## Usage

```powershell
# Standard RMM task: remove whatever agent is present (both kinds), clean DNS
.\Uninstall-DNSFilterAgent.ps1

# See what would be removed, without touching anything
.\Uninstall-DNSFilterAgent.ps1 -TestOnly

# Keep the agent's registry config for a re-key
.\Uninstall-DNSFilterAgent.ps1 -RegClean:$false

# Stuck agent: clean residue even though msiexec failed, and keep the whole log
.\Uninstall-DNSFilterAgent.ps1 -ForceCleanup -FullMsiLog
```

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-RegClean` | `Auto` | `Auto` sends `REGCLEAN=true` only for agents at v2.0.1+; `True` always, `False` never - and `False` also makes the residue pass keep the config keys. |
| `-ForceCleanup` | off | Clear residue for every detected product even after a failed msiexec. Off by default so a failure keeps its evidence. |
| `-DnsCleanup` | `Clean` | `Clean` strips loopback DNS from up adapters; `Report` only lists them. |
| `-TestOnly` | off | List agents found, where they were found, their version and recipe. No changes. |
| `-FullMsiLog` | off | Echo the entire msiexec log instead of the digest. |
| `-LogTailLines` | `40` | Tail size in the digest (10-500). |
| `-LogPath` | `%ProgramData%\iTech\Logs\DNSFilter-Uninstall-<host>.log` | Transcript log. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Nothing installed, or every agent removed with no residue |
| `1` | A removal failed, residue remains (service, directory, key, still-registered product), or a DNS repair failed |
| `2` | Parameter or prerequisite problem |

## Status values in the JSON summary

`not-installed`, `preflight-ok`, `removed`, `removed-with-residue`, `failed`, `error`.

```json
{"script":"Uninstall-DNSFilterAgent","commit":"unstamped","computer":"WS-042","when":"2026-11-25T09:12:44.1180-05:00","action":"uninstall","status":"removed","agents":[{"product":"DNSFilter Agent","code":"{4E66DFE1-8225-4ED8-9C7F-6A56E4125018}","version":"3.6.10","foundBy":"ARP+MsiDatabase","recipe":"modern"}],"removed":["service:DNSFilter Agent","dir:C:\\Program Files\\DNSFilter Agent","key:SOFTWARE\\DNSFilter:Registry64","product:{4E66DFE1-8225-4ED8-9C7F-6A56E4125018}"],"residue":[],"dns":[{"Adapter":"Ethernet","Before":"127.0.0.1,10.0.0.10","After":"10.0.0.10","Action":"loopback-removed"}],"exitCode":0,"detail":"removed 4; residue 0"}
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `status: not-installed` but the client is clearly filtering | The agent is hidden from Add/Remove Programs; check the MSI database and the agent registry keys the script reports, and run `-TestOnly` to see every source it checked. |
| msiexec `1603` | Fatal error during removal - read the digest in the RMM output, then `-FullMsiLog` for the whole thing. |
| msiexec `1605` | Product is not registered any more; treated as already removed, and it does **not** trigger a residue pass. |
| msiexec `1618` | Another installation is running; re-run the task. |
| msiexec `1625` | Blocked by AppLocker or Software Restriction Policies. |
| `status: removed-with-residue` | The product is gone but something survived - a service, the install directory, or a DNS repair that failed. The `residue` array in the JSON names it. |
| `residue: dns-cleanup-failed` | An adapter could not be moved off loopback DNS; the machine may have no working resolver. Fix DNS on that adapter by hand. |
| `status: failed` | Removal failed and residue was deliberately left in place. Read the log, fix the cause, re-run, or accept the risk with `-ForceCleanup`. |
| Tray icon still in the notification area | `HKCU` tray residue belongs to the logged-on user; a SYSTEM task cannot clean another user's hive. The script says so in the output instead of pretending. |
| Re-keying a site | `-RegClean:$false` removes the product but keeps the config trees. |

## Notes

- Run as **SYSTEM**. Both the modern **DNSFilter Agent** and the legacy whitelabel
  **DNS Agent** are removed, so a machine carrying both ends up clean.
- Residue cleanup is deferred until every removal attempt has finished and scoped to
  the products actually removed.
- Exit codes follow the same convention as the other Windows scripts here:
  `0` ok, `1` failed, `2` parameter/prerequisite.

## Script

- `ConnectWise-RMM-Asio/Scripts/Windows/Uninstall-DNSFilterAgent.ps1`

## Vendor references

- Uninstall v2.0.1 or higher: <https://help.dnsfilter.com/hc/en-us/articles/34957633714707-Uninstall-Windows-Roaming-Client-v2-0-1-or-higher>
- Uninstall v1.15.3 and older: <https://help.dnsfilter.com/hc/en-us/articles/24995915099027-Uninstall-Windows-Roaming-Client-v1-15-3-and-older>
- DNSFilter's own reference uninstaller: <https://github.com/DNSFilter/support/blob/master/useragent/windows/uninstallscript.ps1>
