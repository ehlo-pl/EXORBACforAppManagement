<#
.SYNOPSIS
Synchronizes user membership from multiple on-premises AD groups into one Universal Security group.

.DESCRIPTION
The destination's direct user members are reconciled to the union of the users in the source
groups. Nested source groups are expanded recursively. Non-user direct members of the destination
are left unchanged. This is suitable for keeping direct members in a hybrid mail-enabled group
used by an Exchange Online RBAC for Applications scope.

.PARAMETER SourceGroup
One or more source AD group names, distinguished names, GUIDs, or SIDs.

.PARAMETER DestinationGroup
The destination AD group name, distinguished name, GUID, or SID. Must be a Universal Security
group. Mail-enable and synchronize it separately using the organization's Exchange hybrid process.

.EXAMPLE
.\Sync-ADGroupMembers.ps1 -SourceGroup 'GG-App-Mail','GG-App-Shared' `
    -DestinationGroup 'USG-App-Mail-Scope' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]] $SourceGroup,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $DestinationGroup
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -ErrorAction Stop

$destination = Get-ADGroup -Identity $DestinationGroup `
    -Properties GroupScope, GroupCategory, ObjectGUID, SID `
    -ErrorAction Stop

if ($destination.GroupScope -ne 'Universal') {
    throw "Destination group '$($destination.Name)' must have Universal scope."
}

if ($destination.GroupCategory -ne 'Security') {
    throw "Destination group '$($destination.Name)' must be a Security group."
}

$sourceGroups = foreach ($identity in $SourceGroup) {
    $group = Get-ADGroup -Identity $identity -Properties ObjectGUID, SID -ErrorAction Stop
    if ($group.SID.Value -eq $destination.SID.Value) {
        throw "Destination group '$($destination.Name)' cannot also be a source group."
    }
    $group
}

$desiredUsers = @{}
foreach ($group in $sourceGroups) {
    foreach ($member in @(Get-ADGroupMember -Identity $group.DistinguishedName -Recursive -ErrorAction Stop)) {
        if ($member.objectClass -eq 'user') {
            $desiredUsers[$member.SID.Value] = $member
        }
    }
}

$currentUsers = @{}
$otherDestinationMembers = @()
foreach ($member in @(Get-ADGroupMember -Identity $destination.DistinguishedName -ErrorAction Stop)) {
    if ($member.objectClass -eq 'user') {
        $currentUsers[$member.SID.Value] = $member
    }
    else {
        $otherDestinationMembers += $member
    }
}

$toAdd = @(
    $desiredUsers.Values |
        Where-Object { -not $currentUsers.ContainsKey($_.SID.Value) } |
        Sort-Object SamAccountName, DistinguishedName
)
$toRemove = @(
    $currentUsers.Values |
        Where-Object { -not $desiredUsers.ContainsKey($_.SID.Value) } |
        Sort-Object SamAccountName, DistinguishedName
)

$added = @()
$removed = @()
foreach ($member in $toAdd) {
    if ($PSCmdlet.ShouldProcess(
        $destination.Name,
        "Add user '$($member.SamAccountName)'"
    )) {
        Add-ADGroupMember -Identity $destination.DistinguishedName `
            -Members $member.DistinguishedName -Confirm:$false -ErrorAction Stop
        $added += $member.SamAccountName
    }
}

foreach ($member in $toRemove) {
    if ($PSCmdlet.ShouldProcess(
        $destination.Name,
        "Remove user '$($member.SamAccountName)'"
    )) {
        Remove-ADGroupMember -Identity $destination.DistinguishedName `
            -Members $member.DistinguishedName -Confirm:$false -ErrorAction Stop
        $removed += $member.SamAccountName
    }
}

[pscustomobject]@{
    SourceGroups             = @($sourceGroups | ForEach-Object Name | Sort-Object -Unique)
    DestinationGroup         = $destination.Name
    DesiredUserCount         = $desiredUsers.Count
    ExistingUserCount        = $currentUsers.Count
    AdditionsPlanned         = $toAdd.Count
    RemovalsPlanned          = $toRemove.Count
    Added                    = @($added)
    Removed                  = @($removed)
    NonUserMembersPreserved  = $otherDestinationMembers.Count
}
