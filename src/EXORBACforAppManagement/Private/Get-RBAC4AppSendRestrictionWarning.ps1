function Get-RBAC4AppSendRestrictionWarning {
    # Warning text for an existing, module-managed scope group that is not send-restricted. Kept in
    # one place so New-/Set-/Test-RBAC4AppEntry and Invoke-RBAC4AppConfig word it identically (the
    # orchestrators keep delegated warnings that match '*send restriction*').
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )
    "Scope group '$Name' has no send restriction (AcceptMessagesOnlyFromSendersOrMembers is empty), so it can receive mail; run Set-RBAC4AppEntry to restrict it to the owner."
}
