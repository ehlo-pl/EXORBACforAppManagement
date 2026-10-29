function Get-RBAC4AppRoleAssignmentName {
    # Deterministic management role assignment name: "{ShortRoleName}-{DisplayName}" sanitized via
    # Format-RBAC4AppSafeName and capped at the RoleAssignment limit.
    param(
        [Parameter(Mandatory)]
        [string] $ShortRoleName,

        [Parameter(Mandatory)]
        [string] $DisplayName
    )

    Format-RBAC4AppSafeName -Value ('{0}-{1}' -f $ShortRoleName, $DisplayName) -MaxLength $script:RBAC4AppNameMaxLength.RoleAssignment
}
