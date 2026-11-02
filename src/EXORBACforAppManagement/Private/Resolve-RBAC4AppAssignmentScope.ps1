function Resolve-RBAC4AppAssignmentScope {
    # Resolves the effective -AssignmentScope for a -ScopeKind, shared by New-/Set-/Test-RBAC4AppEntry
    # and New-RBAC4AppConfig so they cannot drift:
    #
    #   RecipientGroupScope - role assignments bound directly to the scope group
    #                         (New-ManagementRoleAssignment -RecipientGroupScope); Group kind only
    #   ManagementScope     - role assignments bound to a management scope (-CustomResourceScope)
    #
    # Non-Group kinds always resolve to ManagementScope; explicitly requesting RecipientGroupScope
    # with them throws. Returns the effective value plus warnings for supplied management scope
    # naming parameters that RecipientGroupScope ignores.
    param(
        [Parameter(Mandatory)]
        [string] $ScopeKind,

        [Parameter(Mandatory)]
        [string] $AssignmentScope,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $BoundParameters
    )

    $effective = $AssignmentScope
    if ($ScopeKind -ne 'Group') {
        if ($BoundParameters.ContainsKey('AssignmentScope') -and $AssignmentScope -eq 'RecipientGroupScope') {
            throw "-AssignmentScope RecipientGroupScope can only be used with -ScopeKind Group; -ScopeKind $ScopeKind requires a management scope."
        }
        $effective = 'ManagementScope'
    }

    $warnings = @()
    if ($effective -eq 'RecipientGroupScope') {
        foreach ($p in @('ManagementScopeName', 'ManagementScopePrefix')) {
            if ($BoundParameters.ContainsKey($p)) {
                $warnings += "-$p only applies to -AssignmentScope ManagementScope and was ignored (AssignmentScope is RecipientGroupScope)."
            }
        }
    }

    [pscustomobject]@{
        AssignmentScope = $effective
        Warnings        = $warnings
    }
}
