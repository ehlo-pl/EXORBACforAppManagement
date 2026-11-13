function Set-RBAC4AppScopeGroupSendRestriction {
    # Stops a module-managed scope group from being used as a mail target: always requires sender
    # authentication (RequireSenderAuthenticationEnabled) and, when at least one -ManagedBy owner
    # resolves to a recipient, allows only those owners as senders
    # (AcceptMessagesOnlyFromSendersOrMembers; default owner GraphAPI-Dummy-owner).
    #
    # When no owner resolves, the allowed-senders list cannot be set (Exchange requires real
    # recipients): the send restriction is skipped with a warning and only sender authentication is
    # enforced - the group is still usable as a scope.
    #
    # Used by New-RBAC4AppDistributionGroup / New-RBAC4AppUnifiedGroup right after creation and by
    # Set-RBAC4AppEntry to fix an existing group. Never called for a HybridMailEnabledSecurityGroup
    # (reference-only, mastered on-premises). Returns { SendRestricted; AllowedSenders; Warnings } and
    # also writes each warning; a failed Set-* call throws for the caller to record.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CloudMailEnabledSecurityGroup', 'DistributionList', 'M365Group')]
        [string] $AccessGroupType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $ManagedBy = @($script:RBAC4AppDefaultOwner)
    )

    $warnings = @()
    $allowed = [System.Collections.Generic.List[string]]::new()
    $unresolved = @()
    foreach ($owner in @($ManagedBy | Where-Object { $_ })) {
        $recipient = Get-Recipient -Identity $owner -ErrorAction SilentlyContinue
        $address = if ($recipient) { [string]$recipient.PrimarySmtpAddress } else { '' }
        if ($address) {
            if (-not $allowed.Contains($address)) { $allowed.Add($address) }
        }
        else { $unresolved += $owner }
    }

    $setParams = @{
        Identity                           = $Name
        RequireSenderAuthenticationEnabled = $true
        ErrorAction                        = 'Stop'
    }
    if ($allowed.Count -gt 0) {
        $setParams['AcceptMessagesOnlyFromSendersOrMembers'] = @($allowed)
        if ($unresolved.Count -gt 0) {
            $warnings += ("Scope group '{0}': owner(s) {1} could not be resolved to a recipient and were left out of the send restriction (allowed senders: {2})." -f $Name, ($unresolved -join ', '), (@($allowed) -join ', '))
        }
    }
    else {
        $ownerList = if ($unresolved.Count -gt 0) { $unresolved -join ', ' } else { '(none)' }
        $warnings += ("Scope group '{0}': send restriction skipped - no owner ({1}) resolved to a recipient, so AcceptMessagesOnlyFromSendersOrMembers was not set and only sender authentication is required. Create the owner recipient, then run Set-RBAC4AppEntry to apply it." -f $Name, $ownerList)
    }

    $action = if ($allowed.Count -gt 0) { "Allow only $(@($allowed) -join ', ') to send; require sender authentication" } else { 'Require sender authentication' }
    $applied = $false
    if ($PSCmdlet.ShouldProcess($Name, $action)) {
        if ($AccessGroupType -eq 'M365Group') { Set-UnifiedGroup @setParams }
        # The owner is normally not the operator, so EXO requires the manager-check bypass.
        else { Set-DistributionGroup @setParams -BypassSecurityGroupManagerCheck }
        $applied = $true
    }

    foreach ($w in $warnings) { Write-Warning -Message $w }
    [pscustomobject]@{
        # $true only when the allowed-senders list was actually applied (not under -WhatIf).
        SendRestricted = ($applied -and $allowed.Count -gt 0)
        AllowedSenders = @($allowed)
        Warnings       = @($warnings)
    }
}
