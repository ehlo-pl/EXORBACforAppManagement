function Get-RBAC4AppManagementScopeName {
    # Deterministic management scope name for an application: an explicit -Name wins, otherwise
    # "{Prefix}-{DisplayName}" sanitized via Format-RBAC4AppSafeName (Exchange caps scope names at
    # 64 chars). -Suffix (e.g. "-MailSend", one scope per role) is appended after truncating the
    # name so the total never exceeds the ManagementScope limit.
    param(
        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter()]
        [string] $Prefix = $script:RBAC4AppDefaultManagementScopePrefix,

        [Parameter()]
        [string] $Name,

        [Parameter()]
        [string] $Suffix
    )

    $max = $script:RBAC4AppNameMaxLength.ManagementScope
    $base = if ($Name) { $Name } else { '{0}-{1}' -f $Prefix, $DisplayName }
    # An explicit -Name was historically returned unsanitized; keep that unless a suffix forces a re-cut.
    if ($Name -and -not $Suffix) { return $Name }
    (Format-RBAC4AppSafeName -Value $base -MaxLength ($max - $Suffix.Length)) + $Suffix
}
