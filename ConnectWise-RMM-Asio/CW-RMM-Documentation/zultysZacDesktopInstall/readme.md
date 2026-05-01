# Zultys ZAC Desktop Deployment (ConnectWise RMM / Asio)

## Overview

This script deploys the **Zultys Advanced Communicator (ZAC) Desktop client** using ConnectWise RMM (Asio) as an **on-demand script**.

It performs the following actions:

- Downloads the latest ZAC installer from the Zultys mirror (or uses a provided URL)
- Installs the application silently
- Locates the installed ZAC executable
- Creates a public desktop shortcut with the MX server preconfigured

---

## Features

- Supports **.exe and .msi installers**
- Automatically resolves the **latest ZAC version** from:

  ```text
  https://mirror.zultys.biz/ZAC/
  ```

- Fully compatible with **SYSTEM context execution** (CW RMM)
- Uses **RMM parameter token** for dynamic server assignment
- Provides clear success/failure output (`COMPLIANT` / `NONCOMPLIANT`)

---

## Parameters

### InstallerUrl (Optional)

Default:

```text
https://mirror.zultys.biz/ZAC/
```

- Can be either:
  - Direct `.exe` or `.msi` installer URL
  - Mirror directory URL (script will select latest version automatically)

---

### MxServer (Required via RMM)

This value is passed via ConnectWise RMM using the token:

```text
@mx_server_url@
```

Example value:

```text
itech.mxvirtual.com
```

This is used to build the shortcut argument:

```text
u=server.mxvirtual.com
```

---

### ShortcutName (Optional)

Default:

```text
Zultys ZAC
```

Name of the shortcut created on:

```text
C:\Users\Public\Desktop
```

---

## Shortcut Behavior

The script creates a shortcut equivalent to:

```text
"C:\Program Files\Zultys\ZAC\Bin\zac.exe" u=<MX Server>
```

This ensures:

- Users do not need to manually enter the server
- Seamless SAML login experience (Evo / Entra)

---

## Logging

Installer logs are written to:

```text
C:\ProgramData\iTech\ZultysZAC\ZultysZAC_Install.log
```

---

## ConnectWise RMM Usage

1. Upload script to CW RMM
2. Configure parameter:

   ```text
   mx_server_url
   ```

3. Run script on-demand
4. Enter MX server when prompted

---

## Output

The script returns:

| Output | Meaning |
| ------ | -------- |
| COMPLIANT | Install succeeded |
| NONCOMPLIANT | Install failed |

---

## Notes

- Script runs as **SYSTEM**, installs for all users
- Shortcut is placed in **Public Desktop** for visibility
- EXE installer uses silent switch:

  ```text
  /S
  ```

- If Zultys changes installer behavior, update silent arguments accordingly

---

## Recommendations

- Use mirror directory instead of hardcoding versions
- Validate MX server input before deployment
- Test new ZAC versions before wide rollout

---

## Future Enhancements (Optional)

- Version detection and upgrade logic
- Per-user configuration seeding
- Additional shortcut parameters (username prefill)
- Enhanced logging/telemetry

---

## Author Notes

Designed for MSP environments using:

- ConnectWise RMM (Asio)
- Evo Security SAML or Entra ID

Optimized for simplicity, repeatability, and minimal user interaction.
