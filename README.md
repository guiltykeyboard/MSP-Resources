# MSP-Resources

Scripts and resources for **ConnectWise RMM (Asio)** automation across Windows, Linux, and macOS.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-0078d4?logo=powershell&logoColor=white)](ConnectWise-RMM-Asio/Scripts/Windows/)
[![Bash](https://img.shields.io/badge/Bash-4%2B-4EAA25?logo=gnubash&logoColor=white)](ConnectWise-RMM-Asio/Scripts/Linux/)
[![Python](https://img.shields.io/badge/Python-3.x-3776AB?logo=python&logoColor=white)](tools/)
[![MIT License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Catalog](https://img.shields.io/github/actions/workflow/status/guiltykeyboard/MSP-Resources/build-catalog.yml?label=Catalog&logo=github)](../../actions/workflows/build-catalog.yml)
[![Lint](https://img.shields.io/github/actions/workflow/status/guiltykeyboard/MSP-Resources/lint-scripts.yml?label=Lint&logo=github)](../../actions/workflows/lint-scripts.yml)

---

## Table of Contents

- [Overview](#overview)
- [Script Catalog](#script-catalog)
- [One-Liners for RMM](#one-liners-for-rmm)
- [Recommended Folder Structure](#recommended-folder-structure)
- [Script Documentation Template](#script-documentation-template)
- [License](#license)

---

## Overview

This repository contains a curated collection of scripts for **ConnectWise RMM (Asio)**. Scripts are designed to run as the RMM agent (often **SYSTEM** on Windows). By default, scripts emit **STDOUT/JSON** for easy parsing; many can optionally write artifacts behind a switch.

> Keep your manual notes **outside** the generated block below. The catalog section is auto‑written by CI.

---

## Script Catalog

<!-- GENERATED-CATALOG:START -->
- **ConnectWise-RMM-Asio/Scripts**
  - `ConnectWise-RMM-Asio/Scripts/Windows/backupBitlockerKeys.ps1` — Backup and inventory BitLocker recovery keys on this device.
  - `ConnectWise-RMM-Asio/Scripts/Windows/checkIfBitlockerEnabled.ps1`
<!-- GENERATED-CATALOG:END -->

---

## One-Liners for RMM

Use these templates to download and run a script directly from this repo. They download to a temporary location so you always pull the latest version.

**PowerShell (Windows):**

```powershell
$Base = 'https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
$Rel  = '<path/to/script.ps1>'
$Tmp  = Join-Path $env:TEMP ("script_{0}.ps1" -f ([guid]::NewGuid()))

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Invoke-WebRequest -UseBasicParsing -Uri ("$Base/$Rel") -OutFile $Tmp
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tmp
Remove-Item $Tmp -Force -ErrorAction SilentlyContinue
```

**Bash (Linux/macOS):**

```bash
BASE='https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
REL='<path/to/script.sh>'
OUT="$(mktemp /tmp/script.XXXXXX.sh)"
curl -fsSL "$BASE/$REL" -o "$OUT"
chmod +x "$OUT"
sudo "$OUT"
rm -f "$OUT"
```

**Python (Linux/macOS/Windows with Python 3):**

```bash
BASE='https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
REL='<path/to/script.py>'
OUT="$(mktemp /tmp/script.XXXXXX.py)"
curl -fsSL "$BASE/$REL" -o "$OUT"
python3 "$OUT"
rm -f "$OUT"
```

---

## Recommended Folder Structure

```text
MSP-Resources/
├── ConnectWise-RMM-Asio/
│   └── Scripts/
│       ├── Windows/            # PowerShell (.ps1/.psm1)
│       ├── Linux/              # Bash / Python
│       └── Mac/                # Bash / Python
└── tools/                      # catalog + lint utilities
```

---

## Script Documentation Template

> Copy this block into new scripts (adapt for Bash/Python).

```powershell
<#
.SYNOPSIS
  One‑line summary.
.DESCRIPTION
  A few sentences on what it does and how it is intended to be run in RMM.
.PARAMETER <Name>
  Description.
.EXAMPLE
  Example usage.
#>
```

---

## License

This repository is licensed under the [MIT License](LICENSE).


## Commit ID stamping

Scripts in this repo can include a baked-in Git commit identifier using the literal placeholder `@GIT_COMMIT@`.  
A GitHub Actions workflow (`.github/workflows/stamp-commit.yml`) runs on pushes to `main` and replaces that placeholder with the short SHA of the triggering commit, then makes a follow-up commit with `[skip ci]` to avoid loops.

**How to use in scripts**

Add a line like this near the top of your script:

```powershell
# Baked commit fallback (replaced by CI)
$Script:GIT_COMMIT = '@GIT_COMMIT@'
```

And when you print script metadata, prefer the baked value if Git metadata is unavailable:

```powershell
$commitHash = $null
if (Test-Path (Join-Path $gitRoot '.git')) {
  $commitHash = (git -C $gitRoot rev-parse --short HEAD 2>$null)
}
if (-not $commitHash -and $Script:GIT_COMMIT -and $Script:GIT_COMMIT -ne '@GIT_COMMIT@') {
  $commitHash = $Script:GIT_COMMIT
}
```

This ensures:
- When running in a Git checkout, the live `HEAD` is shown.
- When distributed without `.git` (e.g., RMM), the baked-in commit is shown.