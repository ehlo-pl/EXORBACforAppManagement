function Get-RBAC4AppManagementScopeName {
    # Deterministic management scope name for an application: an explicit -Name wins, otherwise
    # "{Prefix}-{DisplayName}" sanitized via Get-SafeName (Exchange caps scope names at 64 chars).
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
