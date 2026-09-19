<#
.SYNOPSIS
Ensures the scoped Exchange Online distribution list used by New-RBAC4AppEntry exists and is configured.

.DESCRIPTION
New-RBAC4AppDistributionGroup creates a private, hidden, Exchange-Online-only distribution list
(when it does not already exist) to act as the recipient scope for Exchange Online application RBAC.
It is the DistributionList counterpart to New-RBAC4AppUnifiedGroup: the group is created with the
essential attributes (Name/DisplayName/Alias, Type Distribution, and the owner/bootstrap member) via
New-DistributionGroup, then hardened via Set-DistributionGroup (hidden from address lists, sender
authentication required, closed join/depart). If the group already exists it is left in place and a
warning is emitted. A summary object describing the resolved group is returned, matching the shape of
New-RBAC4AppUnifiedGroup so the two helpers are interchangeable behind New-RBAC4AppScopeGroup.

The function supports -WhatIf and -Confirm through SupportsShouldProcess.

.PARAMETER Name
Name and Alias of the distribution list. Expected to already be a safe value (<= 63 chars,
alphanumeric/dash); callers such as New-RBAC4AppEntry sanitize it with Get-SafeName first.

.PARAMETER DisplayName
Display name for the group. Defaults to "{Name} - RBAC for APP".

.PARAMETER ManagedBy
Recipient assigned as the group owner. Defaults to the GraphAPI-Dummy-owner placeholder.

.PARAMETER BootstrapMember
Optional initial member passed during group creation. Defaults to the GraphAPI-Dummy placeholder.

.EXAMPLE
New-RBAC4AppDistributionGroup -Name 'Um365RAo1-ContosoMailApp' -WhatIf -Verbose

Shows the planned distribution list creation without making changes.

.OUTPUTS
PSCustomObject

A summary object describing the group: Name, DisplayName, OwnerRequested (the -ManagedBy input),
OwnerAdded (the owner actually applied/in place), AlreadyExisted, and Group (the underlying Exchange
Online distribution group object, existing or newly created).

.NOTES
Requires a connected Exchange Online session (Get-DistributionGroup, New-DistributionGroup,
Set-DistributionGroup, Get-Recipient). Companion to New-RBAC4AppUnifiedGroup and New-RBAC4AppEntry.
#>
function New-RBAC4AppDistributionGroup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagedBy = 'GraphAPI-Dummy-owner',

        [Parameter()]
        [string] $BootstrapMember = 'GraphAPI-Dummy'
    )

    process {
        if (-not $DisplayName) { $DisplayName = '{0} - RBAC for APP' -f $Name }

        Write-Verbose -Message ("Checking distribution list '{0}'." -f $Name)
        $existingGroup = Get-DistributionGroup -Identity $Name -ErrorAction SilentlyContinue
        if ($existingGroup) {
            $existingOwner = ($existingGroup.ManagedBy | Where-Object { $_ }) -join ', '
            Write-Warning -Message ("Distribution list '{0}' already exists; will only add missing members / assignments." -f $Name)
            Write-Verbose -Message ("Distribution list '{0}' already exists; skipping creation." -f $Name)
            return [pscustomobject]@{
                Name           = $Name
                DisplayName    = $existingGroup.DisplayName
                OwnerRequested = $ManagedBy
                OwnerAdded     = $existingOwner
                AlreadyExisted = $true
                Group          = $existingGroup
            }
        }

        Write-Warning -Message ('{0} do not yet exists' -f $Name)

        # Resolve the requested owner (like members are resolved via Get-Recipient). Unlike a member,
        # an owner cannot be skipped: the group must be created with a ManagedBy, so if the recipient
        # cannot be resolved we warn and fall back to the raw -ManagedBy value.
        $resolvedOwner = $ManagedBy
        $ownerRecipient = Get-Recipient -Identity $ManagedBy -ErrorAction SilentlyContinue
        if ($ownerRecipient) {
            $resolvedOwner = [string]$ownerRecipient.PrimarySmtpAddress
            Write-Verbose -Message ("Owner '{0}' resolved to '{1}'." -f $ManagedBy, $resolvedOwner)
        }
        else {
            Write-Warning -Message ("Owner recipient '{0}' could not be resolved; using the requested value as-is." -f $ManagedBy)
        }

        $initialMembers = @()
        if ($BootstrapMember) { $initialMembers += $BootstrapMember }
        Write-Verbose -Message ("Distribution list '{0}' not found. Creating new group." -f $Name)

        if (-not $PSCmdlet.ShouldProcess($Name, 'Create')) { return }

        try {
            $ndg = New-DistributionGroup `
                -Name $Name `
                -DisplayName $DisplayName `
                -Alias $Name `
                -Type Distribution `
                -ManagedBy $resolvedOwner `
                -Members $initialMembers `
                -ErrorAction Stop
        }
        catch {
            Write-Verbose -Message ("[New-DistributionGroup] Failed for '{0}': {1}" -f $Name, $_.Exception.Message)
            throw
        }

        if ($null -ne $ndg) {
            Write-Verbose -Message ("Distribution list '{0}' created successfully." -f $Name)

            Write-Verbose -Message ("Applying post-creation settings to distribution list '{0}'." -f $Name)
            Set-DistributionGroup -Identity $Name `
                -HiddenFromAddressListsEnabled $true `
                -RequireSenderAuthenticationEnabled $true `
                -MemberJoinRestriction Closed `
                -MemberDepartRestriction Closed `
                -ErrorAction Stop

            $configuredGroup = Get-DistributionGroup -Identity $Name -ErrorAction SilentlyContinue
            if ($configuredGroup) {
                return [pscustomobject]@{
                    Name           = $Name
                    DisplayName    = $configuredGroup.DisplayName
                    OwnerRequested = $ManagedBy
                    OwnerAdded     = $resolvedOwner
                    AlreadyExisted = $false
                    Group          = $configuredGroup
                }
            }

            return [pscustomobject]@{
                Name           = $Name
                DisplayName    = $ndg.DisplayName
                OwnerRequested = $ManagedBy
                OwnerAdded     = $resolvedOwner
                AlreadyExisted = $false
                Group          = $ndg
            }
        }
    }
}
