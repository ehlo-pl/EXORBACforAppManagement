function Get-RBAC4AppSafeDisplayName {
    # Returns the display-name part used by the Get-RBAC4App*Name helpers. Normally this is the
    # display name unchanged (the helpers sanitize the full "{Prefix}-{DisplayName}" string, so
    # existing names stay byte-for-byte identical). When the display name has no character that
    # survives Format-RBAC4AppSafeName (e.g. entirely non-ASCII, such as 'zażółć' minus the
    # ASCII letters, or Kanji), the derived name would collapse to a bare prefix like 'UDLRAo1P-'.
    # In that case fall back to the AppId without dashes (deterministic, unique per application),
    # or throw a descriptive error when no AppId is available. Diacritics are deliberately NOT
    # transliterated: that would rename objects already provisioned for such applications.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $DisplayName,

        [Parameter()]
        [string] $AppId,

        [Parameter()]
        [string] $OverrideHint = 'an explicit name'
    )

    if (Format-RBAC4AppSafeName -Value $DisplayName -MaxLength ([int]::MaxValue)) { return $DisplayName }
    if ($AppId) {
        $fallback = Format-RBAC4AppSafeName -Value $AppId -MaxLength ([int]::MaxValue)
        $fallback = $fallback -replace '-', ''
        if ($fallback) {
            Write-Verbose -Message ("Display name '{0}' has no Exchange-safe characters; using AppId '{1}' to derive the object name." -f $DisplayName, $fallback)
            return $fallback
        }
    }
    throw ("Application display name '{0}' contains no characters usable in an Exchange object name (A-Z, a-z, 0-9, '-'), and no AppId is available as a fallback. Supply {1}." -f $DisplayName, $OverrideHint)
}
