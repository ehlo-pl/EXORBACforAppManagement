function Format-RBAC4AppSafeName {
    # Sanitize a value into an Exchange-safe object name: every character except letters, digits,
    # and dash is DELETED (not replaced - spaces, dots, underscores, etc. simply disappear), then
    # the result is cut to -MaxLength. Truncation is silent and has no collision suffix, so two
    # long names sharing the same first -MaxLength characters map to the same name.
    # Callers normally go through the Get-RBAC4App*Name helpers, which pick the right -MaxLength.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value,

        [int] $MaxLength = $script:RBAC4AppNameMaxLength.Default
    )

    $clean = ($Value -replace '[^A-Za-z0-9\-]', '')
    if ($clean.Length -le $MaxLength) { return $clean }
    $clean.Substring(0, $MaxLength)
}
