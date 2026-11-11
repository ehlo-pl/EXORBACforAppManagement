function Get-RBAC4AppRoleAssignmentName {
    # Deterministic management role assignment name: "{ShortRoleName}-{DisplayName}" sanitized via
    # Format-RBAC4AppSafeName and capped at the RoleAssignment limit. When the display name
    # sanitizes to nothing, -AppId (dashes removed) is used instead (Get-RBAC4AppSafeDisplayName) -
    # there is no explicit-name override for role assignments, so callers should always pass -AppId.
    param(
        [Parameter(Mandatory)]
        [string] $ShortRoleName,

        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter()]
        [string] $AppId
    )

    $DisplayName = Get-RBAC4AppSafeDisplayName -DisplayName $DisplayName -AppId $AppId -OverrideHint 'an application display name containing ASCII letters or digits, or the AppId'
    Format-RBAC4AppSafeName -Value ('{0}-{1}' -f $ShortRoleName, $DisplayName) -MaxLength $script:RBAC4AppNameMaxLength.RoleAssignment
}
