function ConvertFrom-RBAC4AppRecipientFilter {
    # Classifies a management scope RecipientFilter back into the scope kinds
    # ConvertTo-RBAC4AppRecipientFilter produces, tolerating the extra parentheses Exchange Online
    # adds when it stores a filter:
    #
    #   MemberOfGroup -eq '<DN>'                         -> Group      (GroupDistinguishedName)
    #   PrimarySmtpAddress -eq '..' [-or ...]            -> Recipients (Recipients)
    #   CustomAttributeN -eq '<value>'                   -> Tag        (TagAttribute / TagValue)
    #   anything else                                    -> Filter
    #
    # Returns a [pscustomobject]; ScopeKind is $null for an empty filter. Pure: no EXO calls.
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Filter
    )

    $result = [ordered]@{
        ScopeKind              = $null
        GroupDistinguishedName = $null
        Recipients             = @()
        TagAttribute           = $null
        TagValue               = $null
        Filter                 = $Filter
    }

    if (-not $Filter -or -not $Filter.Trim()) { return [pscustomobject]$result }

    function Test-BalancedParenthesis([string] $text) {
        $depth = 0
        $inQuote = $false
        foreach ($ch in $text.ToCharArray()) {
            if ($ch -eq "'") { $inQuote = -not $inQuote; continue }
            if ($inQuote) { continue }
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') {
                $depth--
                if ($depth -lt 0) { return $false }
            }
        }
        return ($depth -eq 0)
    }

    $text = $Filter.Trim()
    while ($text.Length -ge 2 -and $text.StartsWith('(') -and $text.EndsWith(')') -and
        (Test-BalancedParenthesis $text.Substring(1, $text.Length - 2))) {
        $text = $text.Substring(1, $text.Length - 2).Trim()
    }

    $quoted = "'((?:[^']|'')*)'"

    if ($text -match "^MemberOfGroup\s+-eq\s+$quoted$") {
        $result.ScopeKind = 'Group'
        $result.GroupDistinguishedName = $Matches[1].Replace("''", "'")
        return [pscustomobject]$result
    }

    if ($text -match "^(CustomAttribute(?:1[0-5]|[1-9]))\s+-eq\s+$quoted$") {
        $result.ScopeKind = 'Tag'
        $result.TagAttribute = $Matches[1]
        $result.TagValue = $Matches[2].Replace("''", "'")
        return [pscustomobject]$result
    }

    $addressPattern = "PrimarySmtpAddress\s+-eq\s+$quoted"
    $addressMatches = [regex]::Matches($text, $addressPattern, 'IgnoreCase')
    if ($addressMatches.Count -gt 0) {
        $rest = [regex]::Replace($text, $addressPattern, '', 'IgnoreCase')
        $rest = ($rest -replace '-or', '') -replace '[\s\(\)]', ''
        if (-not $rest) {
            $result.ScopeKind = 'Recipients'
            $result.Recipients = @($addressMatches | ForEach-Object { $_.Groups[1].Value.Replace("''", "'") } | Sort-Object -Unique)
            return [pscustomobject]$result
        }
    }

    $result.ScopeKind = 'Filter'
    [pscustomobject]$result
}
