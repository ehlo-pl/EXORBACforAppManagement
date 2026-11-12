function New-RBAC4AppScopeGroup {
    # Ensure the RBAC scoping group exists, dispatching on the requested group kind, and return a
    # uniform summary (Name / DisplayName / OwnerRequested / OwnerAdded / SendRestricted /
    # AlreadyExisted / Group) so callers (New-/Set-RBAC4AppEntry, Invoke-RBAC4AppConfig) treat every
    # scope type the same way.
    #
    #   CloudMailEnabledSecurityGroup  -> create/configure an EXO-mastered mail-enabled security group
    #                                     (New-RBAC4AppDistributionGroup -GroupType Security)
    #   DistributionList               -> create/configure an EXO-only distribution list
    #                                     (New-RBAC4AppDistributionGroup -GroupType Distribution)
    #   M365Group                      -> create/configure a Unified Group (New-RBAC4AppUnifiedGroup)
    #   HybridMailEnabledSecurityGroup -> reference-only: on-prem/hybrid-synced groups are mastered
    #                                     on-premises and are never created or send-restricted here;
    #                                     only their existence is validated (throws if missing).
    #                                     The legacy name MailEnabledSecurityGroup is accepted.
    #
    # SupportsShouldProcess is intentionally NOT declared here: the create logic lives in the two
    # New-RBACforApp*Group helpers (which do gate on ShouldProcess), and $WhatIfPreference propagates
    # into them automatically. The HybridMailEnabledSecurityGroup branch is read-only.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'State changes are delegated to New-RBAC4AppUnifiedGroup / New-RBAC4AppDistributionGroup, which implement ShouldProcess; $WhatIfPreference propagates into them. The HybridMailEnabledSecurityGroup branch is read-only.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CloudMailEnabledSecurityGroup', 'DistributionList', 'M365Group', 'HybridMailEnabledSecurityGroup', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $ManagedBy = @('GraphAPI-Dummy-owner'),

        [Parameter()]
        [string] $BootstrapMember = 'GraphAPI-Dummy',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference
    )

    $AccessGroupType = ConvertTo-RBAC4AppAccessGroupType -AccessGroupType $AccessGroupType
    switch ($AccessGroupType) {
        'CloudMailEnabledSecurityGroup' {
            $params = @{ Name = $Name; GroupType = 'Security'; ManagedBy = $ManagedBy; BootstrapMember = $BootstrapMember }
            if ($PSBoundParameters.ContainsKey('ChangeReference')) { $params['ChangeReference'] = $ChangeReference }
            return New-RBAC4AppDistributionGroup @params
        }

        'M365Group' {
            $params = @{ Name = $Name; ManagedBy = $ManagedBy; BootstrapMember = $BootstrapMember }
            if ($PSBoundParameters.ContainsKey('ChangeReference')) { $params['ChangeReference'] = $ChangeReference }
            return New-RBAC4AppUnifiedGroup @params
        }

        'DistributionList' {
            $params = @{ Name = $Name; GroupType = 'Distribution'; ManagedBy = $ManagedBy; BootstrapMember = $BootstrapMember }
            if ($PSBoundParameters.ContainsKey('ChangeReference')) { $params['ChangeReference'] = $ChangeReference }
            return New-RBAC4AppDistributionGroup @params
        }

        'HybridMailEnabledSecurityGroup' {
            Write-Verbose -Message ("Validating existing mail-enabled security group '{0}' (reference-only; not created)." -f $Name)
            $existing = Get-Recipient -Identity $Name -ErrorAction SilentlyContinue
            if (-not $existing) {
                throw "HybridMailEnabledSecurityGroup '$Name' was not found. On-prem/hybrid-synced groups must already exist; this module does not create them. Supply an existing group via -AccessGroupName."
            }
            $recipientType = [string]$existing.RecipientTypeDetails
            if ($recipientType -notin $script:RBAC4AppSecurityGroupRecipientTypes) {
                throw "Recipient '$Name' was found, but is of type '$recipientType'. -AccessGroupType HybridMailEnabledSecurityGroup requires a mail-enabled security group ($($script:RBAC4AppSecurityGroupRecipientTypes -join ' or '))."
            }
            $existingOwner = @($existing.ManagedBy | Where-Object { $_ })
            $metadataPath = if ($PSBoundParameters.ContainsKey('ChangeReference')) {
                Save-RBAC4AppChangeReferenceRecord -ChangeReference $ChangeReference -Source $MyInvocation.MyCommand.Name -AccessGroupType $AccessGroupType -ScopeGroupName $Name
            }
            else { $null }
            return [pscustomobject]@{
                Name           = $Name
                DisplayName    = $existing.DisplayName
                OwnerRequested = @($ManagedBy)
                OwnerAdded     = $existingOwner
                SendRestricted = $null
                ChangeReference = $ChangeReference
                ChangeReferencePath = $metadataPath
                AlreadyExisted = $true
                Group          = $existing
            }
        }
    }
}
