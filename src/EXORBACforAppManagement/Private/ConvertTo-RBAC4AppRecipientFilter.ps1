function ConvertTo-RBAC4AppRecipientFilter {
    # Builds the OPATH RecipientRestrictionFilter for the management scope that backs an
    # application's RBAC role assignments, from one of four scope kinds:
    #
    #   Group      -> MemberOfGroup -eq '<group DN>'   (direct members only; DL / MESG / M365 Group)
    #   Recipients -> (PrimarySmtpAddress -eq 'a') -or (PrimarySmtpAddress -eq 'b') ...
    #                 (each value resolved through Get-Recipient to its PrimarySmtpAddress, so UPNs,
    #                 aliases, and SMTP addresses are all accepted)
    #   Tag        -> CustomAttributeN -eq '<value>'  (recommended for large / changing sets)
    #   Filter     -> caller-supplied OPATH, passed through as-is
    #
    # The group DN is taken from -GroupDistinguishedName when known (e.g. the object returned when
    # the group was just ensured), otherwise read with Get-Recipient. With -AllowUnresolved (used
    # under -WhatIf, where the group may not exist yet) an unresolvable group falls back to its
    # identity as a placeholder instead of throwing, and unresolvable recipients are kept verbatim.
    # Read-only: never changes anything.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Group', 'Recipients', 'Tag', 'Filter')]
        [string] $ScopeKind,

        [Parameter()]
        [string] $GroupIdentity,

        [Parameter()]
        [string] $GroupDistinguishedName,

        [Parameter()]
        [string[]] $Recipients,

        [Parameter()]
        [string] $TagAttribute = 'CustomAttribute1',

        [Parameter()]
        [string] $TagValue,

        [Parameter()]
        [string] $Filter,

        [Parameter()]
        [switch] $AllowUnresolved
    )

    function Format-OPathValue([string] $value) {
        "'" + $value.Replace("'", "''") + "'"
    }

    switch ($ScopeKind) {
        'Group' {
            $dn = $GroupDistinguishedName
            if (-not $dn) {
                if (-not $GroupIdentity) {
                    throw 'A scope group identity is required to build a Group management scope filter.'
                }
                $rec = Get-Recipient -Identity $GroupIdentity -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($rec -and $rec.DistinguishedName) {
                    $dn = [string]$rec.DistinguishedName
                }
                elseif ($AllowUnresolved) {
                    Write-Verbose -Message ("Could not resolve the distinguished name of scope group '{0}'; using its identity as a placeholder in the management scope filter." -f $GroupIdentity)
                    $dn = $GroupIdentity
                }
                else {
                    throw "Could not resolve the distinguished name of scope group '$GroupIdentity' (required for the MemberOfGroup management scope filter). If the group was just created, Exchange Online may still be replicating it; re-run in a few minutes."
                }
            }
            return 'MemberOfGroup -eq {0}' -f (Format-OPathValue $dn)
        }

        'Recipients' {
            $requested = @($Recipients | Where-Object { $_ })
            if ($requested.Count -eq 0) {
                throw '-ScopeRecipients must contain at least one recipient when -ScopeKind is Recipients.'
            }

            $addresses = foreach ($r in $requested) {
                $rec = Get-Recipient -Identity $r -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($rec -and $rec.PrimarySmtpAddress) {
                    [string]$rec.PrimarySmtpAddress
                }
                elseif ($AllowUnresolved) {
                    [string]$r
                }
                else {
                    Write-Warning -Message ("Recipient not found for '{0}' (excluded from the management scope filter)." -f $r)
                }
            }
            $addresses = @($addresses | Where-Object { $_ } | Sort-Object -Unique)
            if ($addresses.Count -eq 0) {
                throw 'None of the -ScopeRecipients values could be resolved through Get-Recipient; refusing to build an empty management scope filter.'
            }
            if ($addresses.Count -gt 50) {
                Write-Warning -Message ("{0} recipients produce a long management scope filter; consider -ScopeKind Tag (a CustomAttribute stamp) for large or frequently changing sets." -f $addresses.Count)
            }

            if ($addresses.Count -eq 1) {
                return 'PrimarySmtpAddress -eq {0}' -f (Format-OPathValue $addresses[0])
            }
            return (@($addresses | ForEach-Object { '(PrimarySmtpAddress -eq {0})' -f (Format-OPathValue $_) }) -join ' -or ')
        }

        'Tag' {
            if ($TagAttribute -notmatch '^CustomAttribute([1-9]|1[0-5])$') {
                throw "-ScopeTagAttribute must be one of CustomAttribute1..CustomAttribute15 (got '$TagAttribute')."
            }
            if (-not $TagValue) {
                throw 'A tag value is required when -ScopeKind is Tag.'
            }
            return '{0} -eq {1}' -f $TagAttribute, (Format-OPathValue $TagValue)
        }

        'Filter' {
            if (-not $Filter -or -not $Filter.Trim()) {
                throw '-ScopeFilter is required when -ScopeKind is Filter.'
            }
            return $Filter.Trim()
        }
    }
}
