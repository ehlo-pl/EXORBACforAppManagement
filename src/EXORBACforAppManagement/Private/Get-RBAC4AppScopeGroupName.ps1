function Get-RBAC4AppScopeGroupName {
    # Deterministic scope group name for an application: "{Prefix}-{DisplayName}" sanitized via
    # Format-RBAC4AppSafeName. -Suffix (e.g. "-MailSend", used for one group per role) is appended
    # after truncating the base so the total never exceeds the Group limit.
    param(
        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter(Mandatory)]
        [string] $Prefix,

        [Parameter()]
        [string] $Suffix
    )

    $max = $script:RBAC4AppNameMaxLength.Group
    $base = Format-RBAC4AppSafeName -Value ('{0}-{1}' -f $Prefix, $DisplayName) -MaxLength ($max - $Suffix.Length)
    $base + $Suffix
}
