function Get-RBAC4AppAssignmentSet {
    # Reads the application-role management role assignments Get-RBAC4AppEntry works on and applies
    # the server-independent filters (role, enabled state, recipient write scope, assignee type).
    # The application (identity) filter is NOT applied here: it needs the resolved assignee, see
    # Resolve-RBAC4AppAssignee / Test-RBAC4AppAssigneeMatch.
    #
    # With -Role, one Get-ManagementRoleAssignment -Role query per (already normalized) role, so EXO
    # does the role filtering; without it, one unfiltered read narrowed to "Application *" roles.
    #
    # Fail closed: every read uses -ErrorAction Stop, so a failed read throws instead of looking
    # like an empty tenant. The caller turns the exception into one Write-Error per call.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Role = @(),

        [Parameter()]
        [AllowNull()]
        [Nullable[bool]] $Enabled,

        [Parameter()]
        [string[]] $ScopeType = @('Group', 'CustomRecipientScope'),

        [Parameter()]
        [string] $RoleAssigneeType = 'ServicePrincipal'
    )

    $roles = @($Role | Where-Object { $_ })
    $assignments = if ($roles.Count -gt 0) {
        foreach ($r in $roles) { Get-ManagementRoleAssignment -Role $r -ErrorAction Stop }
    }
    else {
        Get-ManagementRoleAssignment -ErrorAction Stop | Where-Object { [string]$_.Role -like 'Application *' }
    }

    @($assignments | Where-Object {
            $_ -and
            ($null -eq $Enabled -or [bool]$_.Enabled -eq $Enabled) -and
            ($ScopeType -contains 'All' -or [string]$_.RecipientWriteScope -in $ScopeType) -and
            ($RoleAssigneeType -eq 'All' -or [string]$_.RoleAssigneeType -eq $RoleAssigneeType)
        })
}
