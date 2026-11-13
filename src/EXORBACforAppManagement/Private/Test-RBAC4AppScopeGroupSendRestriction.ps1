function Test-RBAC4AppScopeGroupSendRestriction {
    # Is an existing scope group send-restricted (Set-RBAC4AppScopeGroupSendRestriction applied)?
    # $true when AcceptMessagesOnlyFromSendersOrMembers lists at least one sender, $false when it is
    # empty, $null when the group object does not carry the property at all (unknown - e.g. a
    # Get-Recipient result), so callers only warn on a definite $false.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [psobject] $Group
    )

    if (-not $Group) { return $null }
    $property = $Group.PSObject.Properties['AcceptMessagesOnlyFromSendersOrMembers']
    if (-not $property) { return $null }
    return (@($property.Value | Where-Object { $_ }).Count -gt 0)
}
