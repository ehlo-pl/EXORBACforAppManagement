function Get-RBAC4AppAssignmentScopeState {
    # Classifies an existing Get-ManagementRoleAssignment object against the management scope it
    # should be bound to:
    #
    #   Target      - bound to -ManagementScopeName via -CustomResourceScope (desired state)
    #   LegacyGroup - bound directly to -LegacyGroupName via the old -RecipientGroupScope model
    #                 (EXO's hidden "<Group>_<GUID>" scope); Set-RBAC4AppEntry migrates these
    #   Other       - bound to anything else
    #
    # CurrentScope is a human-readable name of whatever the assignment is bound to today.
    param(
        [Parameter(Mandatory)]
        [psobject] $Assignment,

        [Parameter(Mandatory)]
        [string] $ManagementScopeName,

        [Parameter()]
        [string] $LegacyGroupName
    )

    $resourceScope = [string]$Assignment.CustomResourceScope
    $recipientWriteScope = [string]$Assignment.RecipientWriteScope
    $legacyName = Resolve-RBAC4AppScopeGroupName -Assignment $Assignment

    $state = 'Other'
    if (($resourceScope -and $resourceScope -ieq $ManagementScopeName) -or
        ([string]$Assignment.CustomRecipientWriteScope -ieq $ManagementScopeName)) {
        $state = 'Target'
    }
    elseif ($LegacyGroupName -and ($recipientWriteScope -in @('Group', 'CustomRecipientScope')) -and
        ([string]$legacyName -ieq $LegacyGroupName)) {
        $state = 'LegacyGroup'
    }

    $current = if ($state -eq 'Target') { $ManagementScopeName }
    elseif ($legacyName) { [string]$legacyName }
    elseif ($resourceScope) { $resourceScope }
    else { $recipientWriteScope }

    [pscustomobject]@{
        State        = $state
        CurrentScope = $current
    }
}
