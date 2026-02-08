# Modify Sleep Settings

[![Platform](https://img.shields.io/badge/Platform-Windows-blue?logo=windows)](../../Scripts/Windows/modify-sleep-settings.ps1)
[![Language](https://img.shields.io/badge/Language-PowerShell-5391FE?logo=powershell)](../../Scripts/Windows/modify-sleep-settings.ps1)

## Synopsis

Keeps Windows devices awake when plugged in (AC) by setting sleep/hibernate timeouts to **Never**, leaving battery settings untouched. Intended for overnight maintenance windows via ConnectWise RMM.

## Quick Run (no temp file)

Run as SYSTEM/Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; iwr https://raw.githubusercontent.com/guiltykeyboard/MSP-Resources/main/ConnectWise-RMM-Asio/Scripts/Windows/modify-sleep-settings.ps1 -UseBasicParsing | iex
```

## What it does

- Detects the active power scheme.
- Sets AC (plugged-in) sleep and hibernate timeouts to **0** (Never).
- Re-applies the active scheme so the changes take effect.
- Does **not** alter battery/DC settings.

## Usage notes

- Run during maintenance windows to keep endpoints online overnight.
- Verify after deployment with `powercfg /getactivescheme` and `powercfg /query` if needed.
- Future plan: a CW RMM monitor + auto-remediation variant can use the same logic.
