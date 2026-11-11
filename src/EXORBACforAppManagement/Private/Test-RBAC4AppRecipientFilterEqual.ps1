function Test-RBAC4AppRecipientFilterEqual {
    # Loose equality for OPATH filters: Exchange Online re-renders a stored filter (extra
    # parentheses, spacing, keyword casing), so compare with whitespace and parentheses removed,
    # case-insensitively.
    param(
        [AllowNull()][AllowEmptyString()][string] $Reference,
        [AllowNull()][AllowEmptyString()][string] $Difference
    )

    $normalize = { param($f) if ($null -eq $f) { '' } else { ($f -replace '[\s\(\)]', '').ToLowerInvariant() } }
    (& $normalize $Reference) -eq (& $normalize $Difference)
}
