function ConvertTo-RBAC4AppEntryRow {
    # Projects one management role assignment, its resolved assignee (Resolve-RBAC4AppAssignee) and
    # its resolved scope (Resolve-RBAC4AppScope) onto the RBAC4App.Entry row Get-RBAC4AppEntry
    # emits. Single source of that row shape: Get-RBAC4AppApplication and Export-RBAC4AppConfig
    # consume exactly these properties and never read Exchange Online again.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [psobject] $Assignment,

        [Parameter(Mandatory)]
        [psobject] $Assignee,

        [Parameter(Mandatory)]
        [psobject] $Scope
    )

    $warnings = @(@($Assignee.Warnings) + @($Scope.Warnings) | Where-Object { $_ } | Select-Object -Unique)

    [pscustomobject][ordered]@{
        PSTypeName               = 'RBAC4App.Entry'
        Name                     = $Assignment.Name
        RoleAssignmentName       = $Assignment.Name
        Role                     = $Assignment.Role
        RoleAssigneeName         = $Assignment.RoleAssigneeName
        RoleAssigneeType         = $Assignment.RoleAssigneeType
        EffectiveUserName        = $Assignment.EffectiveUserName
        App                      = $Assignment.App
        DisplayName              = $Assignee.DisplayName
        AppId                    = $Assignee.AppId
        ServicePrincipalId       = $Assignee.ServicePrincipalId
        ServicePrincipalIdSource = $Assignee.ServicePrincipalIdSource
        Scope                    = $Scope.ScopeName
        ScopeSource              = $Scope.Source
        ManagementScope          = $Scope.ManagementScope
        ScopeKind                = $Scope.ScopeKind
        ScopeFilter              = $Scope.ScopeFilter
        ScopeGroupName           = $Scope.ScopeGroupName
        ScopeGroupType           = $Scope.ScopeGroupType
        ScopeGroupResolved       = [bool]$Scope.GroupResolved
        ScopeMembers             = @($Scope.Members)
        RecipientScope           = $Assignment.RecipientWriteScope
        Enabled                  = $Assignment.Enabled
        Guid                     = $Assignment.Guid
        Identity                 = $Assignment.Identity
        Warnings                 = $warnings
        Errors                   = @()
    }
}
