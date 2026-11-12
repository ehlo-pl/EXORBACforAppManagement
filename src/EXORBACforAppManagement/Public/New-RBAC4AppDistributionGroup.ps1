<#
.SYNOPSIS
Ensures the scoped Exchange Online mail-enabled security group (default) or distribution list used by New-RBAC4AppEntry exists and is configured.

.DESCRIPTION
New-RBAC4AppDistributionGroup creates a hidden, Exchange-Online-mastered group (when it does not
already exist) to act as the recipient scope for Exchange Online application RBAC: a mail-enabled
security group (-GroupType Security, the default; AccessGroupType CloudMailEnabledSecurityGroup) or a
distribution list (-GroupType Distribution; AccessGroupType DistributionList). It is the counterpart
to New-RBAC4AppUnifiedGroup: the group is created with the essential attributes
(Name/DisplayName/Alias, Type, and the owner/bootstrap member) via New-DistributionGroup, then
hardened via Set-DistributionGroup (hidden from address lists, closed join/depart) and send-restricted
(sender authentication required, and only the resolved -ManagedBy owners may send; when no owner
resolves, the allowed-senders list is skipped with a warning). If the group already exists it is left
in place with a warning; an existing group of the other type is an error, and an existing group
without a send restriction gets a warning. A summary object describing the resolved group is
returned, matching the shape of New-RBAC4AppUnifiedGroup so the helpers are interchangeable behind
New-RBAC4AppScopeGroup.

The function supports -WhatIf and -Confirm through SupportsShouldProcess.

.PARAMETER AppName
Application name used to derive the group name. Combined with -Prefix as "{Prefix}-{AppName}",
then sanitized via Format-RBAC4AppSafeName (spaces, tabs, commas, and any other character outside
letters/digits/dash are stripped, since Exchange's Alias rejects them). Mutually exclusive with
-Name.

.PARAMETER Prefix
Prefix prepended to -AppName when deriving the group name. Defaults to the module-wide prefix for
-GroupType: 'USRACo1P' (Security) or 'UDLRAo1P' (Distribution). Only valid with -AppName.

.PARAMETER GroupType
Security (default) creates a mail-enabled security group; Distribution creates a distribution list.

.PARAMETER Name
Name and Alias of the distribution list. Sanitized via Format-RBAC4AppSafeName (<= 63 chars,
alphanumeric/dash only - spaces, tabs, commas, semicolons, and other characters Exchange's Alias
rejects are stripped) regardless of whether the caller already sanitized it. Mutually exclusive
with -AppName / -Prefix.

.PARAMETER DisplayName
Display name for the group. Defaults to "{Name} - RBAC for APP".

.PARAMETER ManagedBy
One or more recipients assigned as the group's owners. Defaults to the GraphAPI-Dummy-owner
placeholder. Each is resolved independently via Get-Recipient; one that cannot be resolved is
still passed through as-is (an owner cannot be skipped the way a member can - the group must be
created with at least one ManagedBy value).

.PARAMETER BootstrapMember
Optional initial member passed during group creation. Defaults to the GraphAPI-Dummy placeholder.

.PARAMETER ChangeReference
Optional change or incident reference to persist in a local metadata file under
~\.EXORBACforAppManagement\<change>.yaml without changing Exchange Online object names.

.EXAMPLE
New-RBAC4AppDistributionGroup -AppName 'ContosoMailApp' -WhatIf -Verbose

Shows the planned mail-enabled security group creation for 'USRACo1P-ContosoMailApp' without making changes.

.EXAMPLE
New-RBAC4AppDistributionGroup -AppName 'ContosoMailApp' -Prefix 'MYORG' -WhatIf

Shows the planned creation for 'MYORG-ContosoMailApp' without making changes.

.EXAMPLE
New-RBAC4AppDistributionGroup -Name 'Um365RAo1-ContosoMailApp' -WhatIf -Verbose

Shows the planned distribution list creation without making changes (explicit name).

.OUTPUTS
PSCustomObject

A summary object describing the group: Name, DisplayName, GroupType, OwnerRequested (the -ManagedBy
input, as an array), OwnerAdded (the owners actually applied/in place, as an array), SendRestricted
($true when only the owners may send, $false when not, $null when unknown), AlreadyExisted, and
Group (the underlying Exchange Online distribution group object, existing or newly created).

.NOTES
Requires a connected Exchange Online session (Get-DistributionGroup, New-DistributionGroup,
Set-DistributionGroup, Get-Recipient). Companion to New-RBAC4AppUnifiedGroup and New-RBAC4AppEntry.
#>
function New-RBAC4AppDistributionGroup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'ByAppName')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByAppName')]
        [ValidateNotNullOrEmpty()]
        [string] $AppName,

        [Parameter(ParameterSetName = 'ByAppName')]
        [ValidateNotNullOrEmpty()]
        [string] $Prefix,

        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayName,

        [Parameter()]
        [ValidateSet('Security', 'Distribution')]
        [string] $GroupType = 'Security',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $ManagedBy = @('GraphAPI-Dummy-owner'),

        [Parameter()]
        [string] $BootstrapMember = 'GraphAPI-Dummy',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference
    )

    process {
        $accessGroupType = if ($GroupType -eq 'Security') { 'CloudMailEnabledSecurityGroup' } else { 'DistributionList' }
        $kind = if ($GroupType -eq 'Security') { 'Mail-enabled security group' } else { 'Distribution list' }
        $expectedRecipientType = if ($GroupType -eq 'Security') { 'MailUniversalSecurityGroup' } else { 'MailUniversalDistributionGroup' }
        if ($PSCmdlet.ParameterSetName -eq 'ByAppName') {
            if (-not $Prefix) { $Prefix = Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $accessGroupType }
            $Name = '{0}-{1}' -f $Prefix, $AppName
        }

        # --- Name/Alias must be free of spaces and other characters Exchange's Alias rejects.
        # Callers such as New-RBAC4AppEntry already pass an already-safe name (sanitizing again is
        # a no-op then), but -AppName/-Prefix are built from raw caller input here, and -Name may
        # also be passed directly by a caller that skipped sanitizing it - always sanitize.
        $Name = Format-RBAC4AppSafeName -Value $Name -MaxLength $script:RBAC4AppNameMaxLength.Group

        if (-not $DisplayName) { $DisplayName = '{0} - RBAC for APP' -f $Name }

        Write-Verbose -Message ("Checking {0} '{1}'." -f $kind.ToLowerInvariant(), $Name)
        $existingGroup = Get-DistributionGroup -Identity $Name -ErrorAction SilentlyContinue
        if ($existingGroup) {
            # Never silently reuse a group of the other kind under the requested name (a distribution
            # list where a security group is expected, or the reverse). An unknown type is accepted.
            $existingTypeProperty = $existingGroup.PSObject.Properties['RecipientTypeDetails']
            $existingType = if ($existingTypeProperty) { [string]$existingTypeProperty.Value } else { '' }
            if ($existingType -and $existingType -ne $expectedRecipientType) {
                throw ("Group '{0}' already exists as '{1}', but -AccessGroupType {2} expects '{3}'. Use the matching -AccessGroupType or another group name." -f $Name, $existingType, $accessGroupType, $expectedRecipientType)
            }
            $existingOwner = @($existingGroup.ManagedBy | Where-Object { $_ })
            $metadataPath = $null
            if ($PSBoundParameters.ContainsKey('ChangeReference')) {
                $metadataPath = Save-RBAC4AppChangeReferenceRecord -ChangeReference $ChangeReference -Source $MyInvocation.MyCommand.Name -AccessGroupType $accessGroupType -ScopeGroupName $Name
            }
            Write-Warning -Message ("{0} '{1}' already exists; will only add missing members / assignments." -f $kind, $Name)
            Write-Verbose -Message ("{0} '{1}' already exists; skipping creation." -f $kind, $Name)
            $sendRestricted = Test-RBAC4AppScopeGroupSendRestriction -Group $existingGroup
            if ($sendRestricted -eq $false) { Write-Warning -Message (Get-RBAC4AppSendRestrictionWarning -Name $Name) }
            return [pscustomobject]@{
                Name           = $Name
                DisplayName    = $existingGroup.DisplayName
                GroupType      = $GroupType
                OwnerRequested = @($ManagedBy)
                OwnerAdded     = $existingOwner
                SendRestricted = $sendRestricted
                ChangeReference = $ChangeReference
                ChangeReferencePath = $metadataPath
                AlreadyExisted = $true
                Group          = $existingGroup
            }
        }

        Write-Warning -Message ('{0} do not yet exists' -f $Name)

        # Resolve each requested owner independently (like members are resolved via Get-Recipient).
        # Unlike a member, an owner cannot be skipped: the group must be created with at least one
        # ManagedBy value, so an owner that cannot be resolved is still passed through as-is rather
        # than dropped.
        $resolvedOwners = [System.Collections.Generic.List[string]]::new()
        foreach ($owner in @($ManagedBy | Where-Object { $_ })) {
            $ownerRecipient = Get-Recipient -Identity $owner -ErrorAction SilentlyContinue
            if ($ownerRecipient) {
                $resolved = [string]$ownerRecipient.PrimarySmtpAddress
                $resolvedOwners.Add($resolved)
                Write-Verbose -Message ("Owner '{0}' resolved to '{1}'." -f $owner, $resolved)
            }
            else {
                Write-Warning -Message ("Owner recipient '{0}' could not be resolved; using the requested value as-is." -f $owner)
                $resolvedOwners.Add($owner)
            }
        }
        $resolvedOwner = @($resolvedOwners)

        $initialMembers = @()
        if ($BootstrapMember) { $initialMembers += $BootstrapMember }
        $metadataPath = if ($PSBoundParameters.ContainsKey('ChangeReference')) {
            Save-RBAC4AppChangeReferenceRecord -ChangeReference $ChangeReference -Source $MyInvocation.MyCommand.Name -AccessGroupType $accessGroupType -ScopeGroupName $Name
        }
        else { $null }
        Write-Verbose -Message ("{0} '{1}' not found. Creating new group." -f $kind, $Name)

        if (-not $PSCmdlet.ShouldProcess($Name, 'Create')) { return }

        try {
            $newDistributionGroupParams = @{
                Name        = $Name
                DisplayName = $DisplayName
                Alias       = $Name
                Type        = $GroupType
                ManagedBy   = $resolvedOwner
                Members     = $initialMembers
                ErrorAction = 'Stop'
            }
            $ndg = New-DistributionGroup @newDistributionGroupParams
        }
        catch {
            Write-Verbose -Message ("[New-DistributionGroup] Failed for '{0}': {1}" -f $Name, $_.Exception.Message)
            throw
        }

        if ($null -ne $ndg) {
            Write-Verbose -Message ("{0} '{1}' created successfully." -f $kind, $Name)

            Write-Verbose -Message ("Applying post-creation settings to {0} '{1}'." -f $kind.ToLowerInvariant(), $Name)
            $setDistributionGroupParams = @{
                Identity                           = $Name
                HiddenFromAddressListsEnabled      = $true
                RequireSenderAuthenticationEnabled = $true
                MemberJoinRestriction              = 'Closed'
                MemberDepartRestriction            = 'Closed'
                ErrorAction                        = 'Stop'
            }
            # The group's owner (ManagedBy) is normally not the operator, so EXO requires the bypass.
            Set-DistributionGroup @setDistributionGroupParams -BypassSecurityGroupManagerCheck

            # --- Send restriction: only the owner(s) may send (skipped with a warning when none resolves).
            $restriction = Set-RBAC4AppScopeGroupSendRestriction -AccessGroupType $accessGroupType -Name $Name -ManagedBy $ManagedBy

            $configuredGroup = Get-DistributionGroup -Identity $Name -ErrorAction SilentlyContinue
            if ($configuredGroup) {
                return [pscustomobject]@{
                    Name           = $Name
                    DisplayName    = $configuredGroup.DisplayName
                    GroupType      = $GroupType
                    OwnerRequested = @($ManagedBy)
                    OwnerAdded     = $resolvedOwner
                    SendRestricted = $restriction.SendRestricted
                    ChangeReference = $ChangeReference
                    ChangeReferencePath = $metadataPath
                    AlreadyExisted = $false
                    Group          = $configuredGroup
                }
            }

            return [pscustomobject]@{
                Name           = $Name
                DisplayName    = $ndg.DisplayName
                GroupType      = $GroupType
                OwnerRequested = @($ManagedBy)
                OwnerAdded     = $resolvedOwner
                SendRestricted = $restriction.SendRestricted
                ChangeReference = $ChangeReference
                ChangeReferencePath = $metadataPath
                AlreadyExisted = $false
                Group          = $ndg
            }
        }
    }
}
