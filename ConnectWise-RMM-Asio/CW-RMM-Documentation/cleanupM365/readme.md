# M365 Language Pack Cleanup (Windows)

Removes **all non-English** Microsoft 365 and OneNote language packs, keeping only the language you specify (default: `en-us`).

- **Script:** `ConnectWise-RMM-Asio/Scripts/Windows/M365Cleanup.ps1`
- **Runs in CW RMM (Asio)** or interactively
- **Output:** timestamped log lines to STDOUT; always exits `0` (inspect logs for summary)
- **Self-update aware:** if the local copy is behind `main`, the script downloads and relaunches the latest version automatically

## Quick Run (CW RMM one‑liner)

Paste this into a **PowerShell** script step in CW RMM to pull the latest version and run it. Change `en-us` to the language you want to keep.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}; $url = 'https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main/ConnectWise-RMM-Asio/Scripts/Windows/M365Cleanup.ps1'; $tmp = Join-Path $env:TEMP ('M365Cleanup-{0}.ps1' -f ([guid]::NewGuid())); Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp; try { & $tmp -Keep 'en-us' -SelfUpdated } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
```

> Tip: Append `-WhatIf` to preview what would be removed without making changes.

## Parameters

- `-Keep <culture>` (string, default `en-us`): Language to keep. All others will be removed.
- `-WhatIf` (switch): Dry run. Writes intended actions to the log without uninstalling anything.

## What it does

The script uses several strategies to find and remove language components, in this order:

1. **Click‑to‑Run / Office Deployment Tool (ODT)** — Detects installed Office/OneNote languages via registry and Add/Remove Programs entries and builds an ODT remove configuration for any languages other than `-Keep`.
2. **Winget (Microsoft Store)** — Scans for Microsoft 365 / OneNote language packs in the Store and uninstalls non‑kept languages.
3. **Appx resource packages** — Removes lingering Office/OneNote resource packages for non‑kept languages across **all users**.

After each operation, it performs a **verification pass** and prints a summary of anything remaining.

## Logging & output

- Logs are timestamped lines like `YYYY-MM-DD HH:MM:SS [odt] ...` or `[winget] ...`.
- A final **Summary** line reports counts removed by winget and appx.
- The script prints **SCRIPT SOURCE** with an optional `(Git commit: abc1234)` so you can match the run to the exact repo version.
- Exit code is `0` to ensure RMM captures the full log. Use log text for success/remaining items.

## Requirements & notes

- **Windows PowerShell 5.1+**
- **Winget** is optional but preferred when present.
- For ODT removals, the script looks for a local `setup.exe` or `officedeploymenttool*.exe`. If not found, it emits guidance to place the tool next to the script; otherwise it proceeds with other strategies.
- When run under CW RMM, progress UIs are suppressed and progress is stamped to STDOUT instead.

## Examples

```powershell
# Keep Portuguese (Portugal), remove all other languages
powershell.exe -ExecutionPolicy Bypass -File .\M365Cleanup.ps1 -Keep 'pt-pt'

# Preview actions only (no changes)
powershell.exe -ExecutionPolicy Bypass -File .\M365Cleanup.ps1 -WhatIf
```

## Troubleshooting

- If you still see entries after the run, check the final "Remaining" sections; some Click‑to‑Run remnants require an additional ODT pass with `setup.exe` available.
- Corporate proxies may block GitHub or winget. The script continues with available methods and logs warnings.

---

**Source:** [`ConnectWise-RMM-Asio/Scripts/Windows/M365Cleanup.ps1`](../../../Scripts/Windows/M365Cleanup.ps1)
