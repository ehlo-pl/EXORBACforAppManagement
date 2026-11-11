function ConvertTo-RBAC4AppApplicationRow {
    # Aggregates the RBAC4App.Entry rows of one assignee (same RoleAssigneeType and
    # RoleAssigneeName) into one RBAC4App.Application row. Pure: no Exchange Online calls.
    #
    # DisplayName/AppId/ServicePrincipalId come from the rows, which already apply the assignee
    # type (a role group has no DisplayName) and the EffectiveUserName fallback. When the rows
    # disagree on ServicePrincipalId, the first is kept and a warning is added.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Entry
    )

    $rows = @($Entry | Where-Object { $_ })
    $first = $rows[0]
    $distinct = { param([object[]] $Values) @($Values | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique) }

    $spIds = & $distinct @($rows | ForEach-Object { $_.ServicePrincipalId })
    $displayName = @($rows | Where-Object { $_.DisplayName } | ForEach-Object { $_.DisplayName }) | Select-Object -First 1
    $appId = @($rows | Where-Object { $_.AppId } | ForEach-Object { $_.AppId }) | Select-Object -First 1
    $spId = @($rows | Where-Object { $_.ServicePrincipalId } | ForEach-Object { $_.ServicePrincipalId }) | Select-Object -First 1

    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($w in (& $distinct @($rows | ForEach-Object { $_.Warnings }))) { $warnings.Add($w) }
    if ($spIds.Count -gt 1) {
        $warnings.Add(("Assignments of '{0}' report different ServicePrincipalId values ({1}); using '{2}'." -f $first.RoleAssigneeName, ($spIds -join ', '), $spId))
    }

    [pscustomobject][ordered]@{
        PSTypeName              = 'RBAC4App.Application'
        DisplayName             = $displayName
        AppId                   = $appId
        ServicePrincipalId      = $spId
        ExoServicePrincipal     = [string]$first.RoleAssigneeName
        RoleAssigneeType        = [string]$first.RoleAssigneeType
        ManagementScopeNames    = @(& $distinct @($rows | ForEach-Object { $_.ManagementScope }))
        ScopeKinds              = @(& $distinct @($rows | ForEach-Object { $_.ScopeKind }))
        ScopeGroupNames         = @(& $distinct @($rows | ForEach-Object { $_.ScopeGroupName }))
        ScopeGroupMembers       = @(& $distinct @($rows | ForEach-Object { $_.ScopeMembers }))
        Roles                   = @(& $distinct @($rows | ForEach-Object { $_.Role }))
        RoleAssignmentNames     = @(& $distinct @($rows | ForEach-Object { $_.Name }))
        EffectiveUserNames      = @(& $distinct @($rows | ForEach-Object { $_.EffectiveUserName }))
        Apps                    = @(& $distinct @($rows | ForEach-Object { $_.App }))
        AssignmentCount         = $rows.Count
        EnabledAssignmentCount  = @($rows | Where-Object { $_.Enabled }).Count
        DisabledAssignmentCount = @($rows | Where-Object { -not $_.Enabled }).Count
        Warnings                = @($warnings)
    }
}
