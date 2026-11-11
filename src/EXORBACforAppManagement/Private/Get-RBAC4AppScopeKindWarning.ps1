function Get-RBAC4AppScopeKindWarning {
    # Returns warning messages for explicitly supplied parameters that the selected -ScopeKind
    # ignores (group parameters outside Group, and kind-specific parameters for the other kinds).
    param(
        [Parameter(Mandatory)]
        [string] $ScopeKind,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $BoundParameters
    )

    $byKind = [ordered]@{
        Group      = @('AccessGroupType', 'AccessGroupName', 'GroupPrefix', 'Members', 'ManagedBy', 'BootstrapMember', 'NewGroupName', 'NewGroupPrefix')
        Recipients = @('ScopeRecipients')
        Tag        = @('ScopeTagAttribute', 'ScopeTagValue')
        Filter     = @('ScopeFilter')
    }

    foreach ($kind in $byKind.Keys) {
        if ($kind -eq $ScopeKind) { continue }
        foreach ($p in $byKind[$kind]) {
            if ($BoundParameters.ContainsKey($p)) {
                "-$p only applies to -ScopeKind $kind and was ignored (ScopeKind is $ScopeKind)."
            }
        }
    }
}
