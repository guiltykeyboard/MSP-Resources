<#
.SYNOPSIS
  Adds an Entra ID user to a local security group.
.DESCRIPTION
  Creates the specified local group when needed, then adds the provided
  AzureAD\user@domain member if it is not already present.
#>

param ()

$GroupName = "@GroupName@"
$GroupDescription = "@GroupDescription@"
$UPNToAdd = "@UPNToAdd@"
$MemberName = "AzureAD\$UPNToAdd"

if ([string]::IsNullOrWhiteSpace($GroupName)) {
    Write-Host "GroupName parameter is empty."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($GroupDescription)) {
    Write-Host "GroupDescription parameter is empty."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($UPNToAdd)) {
    Write-Host "UPNToAdd parameter is empty."
    exit 1
}

# Check if the group already exists
$group = Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue

# If the group does not exist, create it with the provided description
if (-not $group) {
    try {
        New-LocalGroup -Name $GroupName -Description $GroupDescription -ErrorAction Stop | Out-Null
        Write-Host "Group '$GroupName' created with description '$GroupDescription'."
    }
    catch {
        Write-Host "Failed to create group '$GroupName'. Error: $($_.Exception.Message)"
        exit 1
    }
}
else {
    Write-Host "Group '$GroupName' already exists. Skipping creation."
}

# Check whether the user is already a member of the group
$existingMember = Get-LocalGroupMember -Group $GroupName -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq $MemberName
}

if ($existingMember) {
    Write-Host "User '$MemberName' is already a member of group '$GroupName'."
    exit 0
}

# Add the Entra ID user to the group in AzureAD\user@domain format
try {
    Add-LocalGroupMember -Group $GroupName -Member $MemberName -ErrorAction Stop
    Write-Host "User '$MemberName' added to group '$GroupName'."
}
catch {
    Write-Host "Failed to add user '$MemberName' to group '$GroupName'. Error: $($_.Exception.Message)"
    exit 1
}
