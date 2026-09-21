function Resolve-RBAC4AppScope {
    # Resolves a Get-ManagementRoleAssignment object's full recipient scope: the scope group's
    # real name (via the shared Resolve-RBAC4AppScopeGroupName helper), its group type
    # (M365Group / DistributionList / MailEnabledSecurityGroup / $null when it can't be
    # determined), and its resolved membership. This is the group-type-probe + membership-read
    # logic that used to live inline in Get-RegisteredAppWithPermission, generalized so
    # Get-RBAC4AppEntry can use it for both its per-assignment and -ByApplication views.
    #
    # Group type is determined by probing Get-UnifiedGroup first (M365Group), then
    # Get-DistributionGroup - whose RecipientTypeDetails distinguishes a plain distribution list
    # ('MailUniversalDistributionGroup') from a mail-enabled security group
    # ('MailUniversalSecurityGroup'), so both DistributionList and MailEnabledSecurityGroup scope
    # groups are read through the same cmdlet.
    #
    # The group/member probe runs for any recipient scope that resolves to a name - both the
    # 'Group' write-scope (recovered via CustomResourceScope) and 'CustomRecipientScope' (whose
    # CustomRecipientWriteScope commonly holds a group identity directly, the way
    # New-RBAC4AppEntry's own -AccessGroupType DistributionList/MailEnabledSecurityGroup scopes
    # are read back). A scope name that isn't a group (e.g. a genuine recipient filter) simply
    # resolves to no type/members, same as an unresolvable one.
    #
    # Results are cached per distinct scope *name* in the caller-supplied $Cache hashtable, since
    # the same scope group commonly backs more than one assignment/application and re-reading it
    # would be wasteful. Every other recipient scope (Organization, MyGAL, Self, ...) has no name
    # at all (Resolve-RBAC4AppScopeGroupName returns $null) and resolves to nothing.
    #
    # Returns a [pscustomobject] with ScopeName, ScopeGroupType, and Members (always an array,
    # possibly empty). Never throws; an unresolvable scope group produces a warning and a $null
    # ScopeGroupType with no members.
    param(
        [Parameter(Mandatory)]
        [psobject] $Assignment,

        [Parameter(Mandatory)]
        [hashtable] $Cache
    )

    $scopeName = Resolve-RBAC4AppScopeGroupName -Assignment $Assignment

    if (-not $scopeName) {
        return [pscustomobject][ordered]@{
            ScopeName      = $scopeName
            ScopeGroupType = $null
            Members        = @()
        }
    }

    if ($Cache.ContainsKey($scopeName)) {
        $cached = $Cache[$scopeName]
        return [pscustomobject][ordered]@{
            ScopeName      = $scopeName
            ScopeGroupType = $cached.ScopeGroupType
            Members        = $cached.Members
        }
    }

    $groupType = $null
    $members = @()

    if (Get-UnifiedGroup -Identity $scopeName -ErrorAction SilentlyContinue) {
        $groupType = 'M365Group'
        $links = @(Get-UnifiedGroupLinks -Identity $scopeName -LinkType Members -ErrorAction SilentlyContinue)
        $members = @($links | ForEach-Object {
                if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
            } | Where-Object { $_ } | Select-Object -Unique)
    }
    else {
        $dist = Get-DistributionGroup -Identity $scopeName -ErrorAction SilentlyContinue
        if ($dist) {
            $groupType = if ([string]$dist.RecipientTypeDetails -eq 'MailUniversalSecurityGroup') { 'MailEnabledSecurityGroup' } else { 'DistributionList' }
            $links = @(Get-DistributionGroupMember -Identity $scopeName -ErrorAction SilentlyContinue)
            $members = @($links | ForEach-Object {
                    if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
                } | Where-Object { $_ } | Select-Object -Unique)
        }
        else {
            Write-Warning -Message ("Could not resolve scope group '{0}' via Get-UnifiedGroup or Get-DistributionGroup; its type and membership will be omitted." -f $scopeName)
        }
    }

    $members = @($members | Sort-Object -Unique)
    $Cache[$scopeName] = [pscustomobject][ordered]@{
        ScopeGroupType = $groupType
        Members        = $members
    }

    [pscustomobject][ordered]@{
        ScopeName      = $scopeName
        ScopeGroupType = $groupType
        Members        = $members
    }
}
