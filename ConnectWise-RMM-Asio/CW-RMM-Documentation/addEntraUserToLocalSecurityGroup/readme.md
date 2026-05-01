# Add Entra User to Local Security Group (CW RMM / Asio)

## Overview

This script adds a specified **Microsoft Entra (Azure AD) user** to a
**local security group** on a Windows endpoint using ConnectWise RMM (Asio).

It is designed for **on-demand execution** or **automation workflows**, using
RMM parameter tokens for flexibility across environments.

---

## What the Script Does

- Validates required input parameters from RMM
- Ensures the target local group exists (creates it if missing)
- Adds the specified Entra user to the local group
- Skips if the user is already a member
- Outputs clear status for RMM (`COMPLIANT` / `NONCOMPLIANT`)

---

## Parameters (CW RMM Tokens)

The script expects the following parameters to be defined in ConnectWise RMM:

### GroupName

```text
@GroupName@
```

- Name of the local security group
- Example: `Remote Desktop Users`

---

### GroupDescription (Optional)

```text
@GroupDescription@
```

- Description used when creating the group (if it does not exist)

---

### UPNToAdd

```text
@UPNToAdd@
```

- User Principal Name (email) of the Entra user
- Example:

```text
user@domain.com
```

---

## How It Works

The script formats the Entra identity as:

```text
AzureAD\user@domain.com
```

This is the required format for adding Entra users to local groups on
Entra-joined or hybrid devices.

---

## ConnectWise RMM Usage

1. Upload script to CW RMM
2. Configure parameters:
   - `GroupName`
   - `GroupDescription` (optional)
   - `UPNToAdd`
3. Run the script on-demand or via automation

---

## Output

| Output | Meaning |
| ------ | ------- |
| COMPLIANT | User successfully added or already a member |
| NONCOMPLIANT | Error occurred during execution |

---

## Requirements

- Device must be:
  - Entra-joined OR Hybrid-joined
- Script must run as:
  - **SYSTEM context** (default in CW RMM)
- User must exist in Entra ID

---

## Notes

- Script uses PowerShell local group cmdlets (`Add-LocalGroupMember`)
- Duplicate membership attempts are safely ignored
- Group is created automatically if it does not exist

---

## Common Use Cases

- Granting local admin access to Entra users
- Adding users to Remote Desktop Users group
- Standardizing permissions across endpoints

---

## Example Scenario

| Parameter | Value |
| --------- | ----- |
| GroupName | Administrators |
| UPNToAdd | `tech@company.com` |

Result:

```text
AzureAD\tech@company.com added to local Administrators group
```

---

## Future Enhancements (Optional)

- Bulk user support
- Removal mode (remove user from group)
- Logging to central system or RMM custom fields
- Group membership reporting

---

## Author Notes

Designed for MSP environments using:

- ConnectWise RMM (Asio)
- Microsoft Entra ID (Azure AD)

Built to be safe, repeatable, and parameter-driven for multi-tenant use.
