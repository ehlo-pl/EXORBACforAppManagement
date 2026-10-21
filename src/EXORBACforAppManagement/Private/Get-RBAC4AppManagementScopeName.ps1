function Get-RBAC4AppManagementScopeName {
    # Generated names for all RBAC objects use the shared 64-character cap and hash-safe truncation.
    # An explicit -Name remains an override and is passed through unchanged.
    param(
        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter()]
        [string] $Prefix = 'MSRAo1P',

        [Parameter()]
        [string] $Name
    )

    if ($Name) { return $Name }
    Get-SafeName -s ('{0}-{1}' -f $Prefix, $DisplayName) -max 64
}
