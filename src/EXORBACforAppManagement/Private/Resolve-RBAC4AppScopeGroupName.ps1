function Resolve-RBAC4AppScopeGroupName {
    # Resolves a Get-ManagementRoleAssignment object's real recipient scope group identity.
    #
    # For RecipientWriteScope 'CustomRecipientScope', CustomRecipientWriteScope holds it directly.
    # For RecipientWriteScope 'Group' (what -RecipientGroupScope produces, i.e. every assignment
    # this module creates), CustomRecipientWriteScope is EMPTY on a real tenant: the group is
    # referenced via CustomResourceScope, the name of an auto-created ManagementScope object whose
    # name follows the pattern "<GroupName>_<GUID>" - confirmed against a real tenant, e.g.
    # "Um365RAo1-Test03_20d5848c-4d61-4b82-a44f-205adc37321f" for group "Um365RAo1-Test03". The
    # GUID suffix is stripped to recover the group name directly, with no extra EXO round trip.
    # If CustomResourceScope doesn't match that pattern (e.g. a scope not created by this module),
    # the raw value is returned as-is; the caller's own group-type resolution will then simply fail
    # to find it, same as any other unresolvable scope name.
    #
    # Returns $null when no scope group name can be determined at all.
    param(
        [Parameter(Mandatory)]
        [psobject] $Assignment
    )

    $writeScope = [string]$Assignment.RecipientWriteScope

    if ($writeScope -eq 'CustomRecipientScope') {
        if ($Assignment.CustomRecipientWriteScope) { return [string]$Assignment.CustomRecipientWriteScope }
        return $null
    }

    if ($writeScope -eq 'Group' -and $Assignment.CustomResourceScope) {
        $resourceScopeName = [string]$Assignment.CustomResourceScope
        if ($resourceScopeName -match '^(.+)_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            return $Matches[1]
        }
        return $resourceScopeName
    }

    return $null
}
