function ConvertTo-RBAC4AppRoleName {
    # Normalize a short application-role name (e.g. Mail.Send) to its full EXO role
    # name (Application Mail.Send). Unknown / already-normalized values pass through.
    param(
        [string] $Role
    )

    if (-not $Role) { return $Role }

    $roleMap = Get-AppRoleMap
    if ($roleMap.Contains($Role)) { return $Role }

    $applicationRole = 'Application {0}' -f $Role
    if ($roleMap.Contains($applicationRole)) { return $applicationRole }

    return $Role
}
