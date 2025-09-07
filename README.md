# MSP‑Resources

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](#) [![Platform](https://img.shields.io/badge/Target-RMM%20(SYSTEM)-informational)](#) [![License](https://img.shields.io/badge/License-MIT-green)](#license) [![Catalog](https://img.shields.io/github/actions/workflow/status/guiltykeyboard/MSP-Resources/build-catalog.yml?label=Catalog&logo=github)](#optional-auto-generate-the-catalog)

Scripts for **IT Managed Service Providers (MSPs)** to run in RMM platforms (ConnectWise RMM/Asio, NinjaOne, Datto RMM, N‑able, Kaseya, etc.).

This README is designed to **scale** as more scripts are added. It includes:
- A quick start
- A searchable **Script Catalog** with collapsible details
- A standard **Script Doc Template** you can copy for new scripts

---

## Quick Start

- **Most RMMs run as SYSTEM.** Scripts here are written to work in that context. When a script also supports manual runs, we keep `#Requires -RunAsAdministrator` to remind admins to elevate.
- **Outputs default to STDOUT/JSON.** Many scripts avoid writing local files unless you pass an explicit switch (e.g., `-WriteFiles`).
- **One‑liner usage.** Each script lists a copy‑paste PowerShell one‑liner to download and run from GitHub Raw.

> **Search tips:** Use your browser’s find (⌘/Ctrl+F) to jump to script names, OS, or RMM. Each entry lives in a collapsible section to keep this page tidy.

---

## Script Catalog

### Generated index
<!-- GENERATED-CATALOG:START -->
<!-- GENERATED-CATALOG:END -->

### ConnectWise RMM (Asio) > Windows

<details>
<summary><strong>BitLocker Recovery Key Backup</strong> — Export recovery passwords/IDs; optional AD backup; RMM‑friendly JSON & table output</summary>

**Path:** `ConnectWise-RMM-Asio/Scripts/backupBitlockerKeys.ps1`

**What it does**
- Enumerates BitLocker **OS** and **Data** volumes.
- Extracts **Recovery Password** and **Key Protector ID** per volume (uses `manage-bde` for cross‑build reliability).
- Optional **AD DS backup** of protectors when domain‑joined (`-AttemptADBackup`).
- Default: **no files** — prints a compact table + JSON to STDOUT. Use `-WriteFiles` to emit TXT/CSV/JSON under `C:\ProgramData\CW-RMM\BitLocker\`.

**Prerequisites**
- PowerShell 5.1+
- BitLocker tools available (`Get-BitLockerVolume`)
- Includes `#Requires -RunAsAdministrator`: **not required** when run by RMM as SYSTEM, but kept for manual runs to enforce elevation.

**Parameters**
- `-Quiet` — JSON only (no table/log lines)
- `-WriteFiles` — write TXT/CSV/JSON artifacts to disk (opt‑in)
- `-OutputRoot <string>` — artifact folder when `-WriteFiles` is used (default `C:\ProgramData\CW-RMM\BitLocker`)
- `-AttemptADBackup` — attempt AD DS backup of each recovery protector

**Exit Codes**
- `0` — success with at least one recovery password discovered
- `2` — no BitLocker or no recovery passwords (still outputs JSON/table)
- `1` — error

**RMM one‑liner (download & run)**
```powershell
$Base = 'https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
$Rel  = 'ConnectWise-RMM-Asio/Scripts/backupBitlockerKeys.ps1'
$Out  = 'C:\ProgramData\CW-RMM\Scripts\backupBitlockerKeys.ps1'
$null = New-Item -ItemType Directory -Path (Split-Path $Out) -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -UseBasicParsing -Uri ("$Base/$Rel") -OutFile $Out
# JSON only (best for parsing):
$Json = & powershell.exe -ExecutionPolicy Bypass -File $Out -Quiet
$Obj  = $Json | ConvertFrom-Json
Write-Host ("Found {0} entries; AnyRecovery={1}" -f $Obj.Count, $Obj.AnyRecovery)
```

</details>

<details>
<summary><strong>BitLocker Enabled Detection</strong> — Detect protection on drives C, D, E, F; table + JSON output</summary>

**Path:** `ConnectWise-RMM-Asio/Scripts/checkIfBitlockerEnabled.ps1`

**What it does**
- Checks drives **C, D, E, F**.
- Outputs a human‑readable **table** and a compact **JSON** line (use `-Quiet` for JSON only).

**Prerequisites**
- PowerShell 5.1+
- BitLocker feature/tools available (`Get-BitLockerVolume`)

**Exit Codes**
- `0` — at least one drive is protected (ProtectionStatus = On)
- `2` — none protected
- `1` — error (e.g., BitLocker tools missing)

**RMM one‑liner (download & run)**
```powershell
$Base = 'https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
$Rel  = 'ConnectWise-RMM-Asio/Scripts/checkIfBitlockerEnabled.ps1'
$Out  = 'C:\ProgramData\CW-RMM\Scripts\checkIfBitlockerEnabled.ps1'
$null = New-Item -ItemType Directory -Path (Split-Path $Out) -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -UseBasicParsing -Uri ("$Base/$Rel") -OutFile $Out
powershell.exe -ExecutionPolicy Bypass -File $Out
```

</details>

---

## Script Doc Template

> Copy this block below when documenting a new script. Keep script docs short in the main README and expand in a per‑folder `README.md` if needed.

<details>
<summary><strong>Script Name</strong> — short one‑line description</summary>

**Path:** `folder/path/scriptName.ps1`

**What it does**
- One or two bullet points
- Focus on outcomes and artifacts

**Prerequisites**
- PowerShell/OS/feature requirements
- Notes about SYSTEM vs. manual runs; include `#Requires -RunAsAdministrator` guidance if applicable

**Parameters**
- `-ExampleSwitch` — what it controls
- `-AnotherParam <type>` — what it does

**Exit Codes**
- `0` — success definition
- `2` — partial/none found
- `1` — error

**RMM one‑liner (download & run)**
```powershell
$Base = 'https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
$Rel  = 'folder/path/scriptName.ps1'
$Out  = 'C:\ProgramData\CW-RMM\Scripts\scriptName.ps1'
$null = New-Item -ItemType Directory -Path (Split-Path $Out) -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -UseBasicParsing -Uri ("$Base/$Rel") -OutFile $Out
powershell.exe -ExecutionPolicy Bypass -File $Out
```

</details>

---

## Optional: Auto‑generate the catalog

You can auto‑rebuild this README’s Script Catalog on each push using a GitHub Action.

**1) Workflow** — save as `.github/workflows/build-catalog.yml`:
```yaml
name: Build Script Catalog
on:
  push:
    branches: [ main ]
  workflow_dispatch: {}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate catalog
        run: |
          python3 tools/build_catalog.py
      - name: Commit changes
        run: |
          if [[ -n "$(git status --porcelain)" ]]; then
            git config user.name "github-actions"
            git config user.email "actions@github.com"
            git add README.md
            git commit -m "chore: auto-update script catalog"
            git push
          fi
```

**2) Generator script** — save as `tools/build_catalog.py`:
```python
#!/usr/bin/env python3
"""
README catalog generator (enhanced).
- Scans known script roots and collects script paths.
- Extracts .SYNOPSIS (if present) from PowerShell comment-based help blocks.
- Rewrites the block between <!-- GENERATED-CATALOG:START --> and <!-- GENERATED-CATALOG:END -->
  with a grouped, readable index: per root folder, list each script with its synopsis.
"""
from pathlib import Path
import re
import sys

REPO = Path(__file__).resolve().parents[1]
README = REPO / "README.md"

ROOTS = [
    REPO / "ConnectWise-RMM-Asio" / "Scripts",
]

PS_EXTS = {".ps1", ".psm1", ".ps1xml"}

def synopsis_for(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""
    # Match a comment-help block and pull .SYNOPSIS line
    m = re.search(r"<#([\s\S]*?)#>", text, re.MULTILINE)
    if not m:
        return ""
    block = m.group(1)
    syn = re.search(r"(?im)^\s*\.SYNOPSIS\s*\n\s*(.+)", block)
    if syn:
        return syn.group(1).strip()
    return ""

def collect():
    grouped = {}
    for root in ROOTS:
        if not root.exists():
            continue
        key = root.relative_to(REPO).as_posix()
        items = []
        for p in sorted(root.rglob("*")):
            if p.is_file() and (p.suffix.lower() in PS_EXTS or p.name.lower() == "checkifbitlockerenabled"):
                rel = p.relative_to(REPO).as_posix()
                syn = synopsis_for(p)
                items.append((rel, syn))
        if items:
            grouped[key] = items
    return grouped

START = "<!-- GENERATED-CATALOG:START -->"
END   = "<!-- GENERATED-CATALOG:END -->"

if not README.exists():
    print("README.md not found; aborting.")
    sys.exit(0)

data = collect()
lines = []
for group, items in sorted(data.items()):
    lines.append(f"- **{group}**")
    for rel, syn in items:
        if syn:
            lines.append(f"  - `{rel}` — {syn}")
        else:
            lines.append(f"  - `{rel}`")
if not lines:
    lines = ["- _No scripts found yet_"]

new_block = START + "\n" + "\n".join(lines) + "\n" + END

md = README.read_text(encoding="utf-8")
if START in md and END in md:
    pre, rest = md.split(START, 1)
    _, post = rest.split(END, 1)
    new_md = pre + new_block + post
else:
    new_md = md.rstrip() + "\n\n" + new_block + "\n"

if new_md != md:
    README.write_text(new_md, encoding="utf-8")
    print("Updated README.md with grouped catalog.")
else:
    print("No README changes needed.")
```

Place the `<!-- GENERATED-CATALOG:START -->` and `<!-- GENERATED-CATALOG:END -->` markers wherever you want the auto‑list to appear (e.g., under a “Generated index” sub‑section).

---

## Contributing
- Use clear folder paths (e.g., `ConnectWise-RMM-Asio/Scripts/…`).
- Follow the **Script Doc Template** above for each addition.
- Prefer **STDOUT/JSON** over writing local files unless an explicit switch is provided.

## License
Unless otherwise noted, scripts are provided **as‑is** without warranty. Review and test before production use.
