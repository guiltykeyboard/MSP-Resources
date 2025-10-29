# Convert Windows Retail to OEM_DM

[![Lint Status](https://img.shields.io/badge/Lint-Passing-brightgreen?style=flat-square)](https://github.com/guiltykeyboard/MSP-Resources)
[![PowerShell](https://img.shields.io/badge/Script-PowerShell-blue?style=flat-square&logo=powershell)](https://github.com/guiltykeyboard/MSP-Resources)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey?style=flat-square&logo=windows)](https://github.com/guiltykeyboard/MSP-Resources)

## Synopsis

Converts Windows 10 or 11 Professional Retail installations to OEM_DM channel using the embedded OEM key from the system firmware (MSDM table).  
Ideal for ConnectWise RMM deployment where automation, silent execution, and reliable activation logging are required.

---

## Overview

This script automates converting a **Windows 10 or 11 Professional Retail** installation to use the **OEM_DM** channel by applying the embedded **OEM product key** stored in system firmware.  
It performs detection, conversion, and activation in a single, non-interactive run.

---

## Script Details

| Property | Value |
|-----------|--------|
| **Script Name** | `convertWindowsRetailToOEM.ps1` |
| **Purpose** | Switch Retail Windows installations to OEM_DM and activate with the embedded OEM key |
| **Tested OS Versions** | Windows 10 Pro, Windows 11 Pro |
| **Execution Context** | SYSTEM or Administrator |
| **Estimated Runtime** | < 1 minute |
| **Requires Reboot** | No |
| **Output Format** | Timestamped log lines with `[INFO]`, `[WARN]`, or `[ERROR]` tags |

---

## Parameters

This script does not require any parameters. All detection and activation steps are handled automatically.

---

## Key Features

- Detects and validates the embedded OEM product key.
- Clears existing KMS or Volume license configuration.
- Installs the OEM key and performs online activation.
- Provides structured, timestamped log output for RMM monitoring.
- Returns standardized **exit codes** for reliable success/failure detection.

---

## Exit Codes

| Code | Meaning |
|------|----------|
| `0` | ✅ Success — Channel is OEM_DM and Windows is activated |
| `1` | ❌ Failure — No embedded OEM key found in BIOS/firmware |
| `2` | ⚠️ General error — Edition mismatch, activation failure, or license read issue |
| `3` | ⚙️ Partial success — Channel switched to OEM_DM, but activation not completed |

These codes are also documented in the script’s `.RETURNS` section for quick reference.

---

## RMM Integration

### Recommended Execution Settings

- **Platform:** Windows  
- **Run As:** SYSTEM  
- **Requires User Logged In:** No  
- **Reboot:** Do not reboot automatically  
- **Output Handling:** Capture script output in logs for audit trail  

### Example Output

```text
2025-10-28 08:41:15 [INFO] Starting Retail → OEM_DM switch + activation.
2025-10-28 08:41:15 [INFO] Detected EditionID: Professional
2025-10-28 08:41:16 [INFO] Embedded OEM key detected in firmware.
2025-10-28 08:41:17 [INFO] Installing OEM key...
2025-10-28 08:41:21 [INFO] SUCCESS: Channel is OEM_DM and LicenseStatus=1 (activated).
```

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|----------|---------------|------------|
| Script exits with `1` | No embedded key detected | Verify device ships with Windows OEM license (MSDM present) |
| Script exits with `2` | Edition mismatch or activation endpoint blocked | Confirm Pro edition, ensure internet access to Microsoft activation servers |
| Script exits with `3` | OEM key installed but not activated | Wait for activation retry or run `/ato` manually when online |

---

## Related Scripts

- [checkWindowsLicenseChannel.ps1](../checkWindowsLicenseChannel/readme.md) — Retrieves current Windows license channel and status for reporting.  
- [activateWindowsWithKey.ps1](../activateWindowsWithKey/readme.md) — Activates Windows using a provided product key.

---

## Version History

| Version | Date | Changes |
|----------|------|----------|
| **1.0.0** | 2025-10-28 | Initial release — OEM conversion & activation logic |
| **1.0.1** | 2025-10-28 | Added logging improvements and exit code documentation |

---

## Author

**Michael Stoffel**  
*Vice President of IT Services, iTech*  
[itechwv.com](https://itechwv.com)  
[GitHub Repository](https://github.com/guiltykeyboard/MSP-Resources)
