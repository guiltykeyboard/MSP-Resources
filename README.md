# MSP-Resources

Scripts and resources for **ConnectWise RMM (Asio)** automation across Windows, Linux, and macOS.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-0078d4?logo=powershell&logoColor=white)](#)
[![Bash](https://img.shields.io/badge/Bash-4%2B-4EAA25?logo=gnubash&logoColor=white)](#)
[![Python](https://img.shields.io/badge/Python-3.x-3776AB?logo=python&logoColor=white)](#)
[![MIT License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Catalog](https://img.shields.io/github/actions/workflow/status/guiltykeyboard/MSP-Resources/build-catalog.yml?label=Catalog&logo=github)](../../actions/workflows/build-catalog.yml)
[![Lint](https://img.shields.io/github/actions/workflow/status/guiltykeyboard/MSP-Resources/lint-scripts.yml?label=Lint&logo=github)](../../actions/workflows/lint-scripts.yml)

---

## Table of Contents
- [Overview](#overview)
- [Script Catalog](#script-catalog)
- [One‑Liners for RMM](#one-liners-for-rmm)
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
  - `ConnectWise-RMM-Asio/Scripts/backupBitlockerKeys.ps1` — Backup BitLocker Recovery Keys to files and optionally to Active Directory.
<!-- GENERATED-CATALOG:END -->

---

## One‑Liners for RMM

Use these templates to download and run a script directly from this repo.

**PowerShell (Windows):**
```powershell
$Base = 'https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
$Rel  = '<path/to/script.ps1>'
$Out  = 'C:\\ProgramData\\CW-RMM\\Scripts\\script.ps1'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $Out) -ErrorAction SilentlyContinue
Invoke-WebRequest -UseBasicParsing -Uri ("$Base/$Rel") -OutFile $Out
powershell.exe -ExecutionPolicy Bypass -File $Out
```

**Bash (Linux/macOS):**
```bash
BASE='https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
REL='<path/to/script.sh>'
OUT='/tmp/script.sh'
mkdir -p "$(dirname "$OUT")"
curl -fsSL "$BASE/$REL" -o "$OUT"
chmod +x "$OUT"
sudo "$OUT"
```

**Python (Linux/macOS/Windows with Python 3):**
```bash
BASE='https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main'
REL='<path/to/script.py>'
OUT='/tmp/script.py'
mkdir -p "$(dirname "$OUT")"
curl -fsSL "$BASE/$REL" -o "$OUT"
python3 "$OUT"
```

---

## Recommended Folder Structure

```
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