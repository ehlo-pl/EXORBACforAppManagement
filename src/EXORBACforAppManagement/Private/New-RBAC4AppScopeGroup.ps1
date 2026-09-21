function New-RBAC4AppScopeGroup {
    # Ensure the RBAC scoping group exists, dispatching on the requested group kind, and return a
    # uniform summary (Name / DisplayName / OwnerRequested / OwnerAdded / AlreadyExisted / Group) so
    # callers (New-/Set-RBAC4AppEntry) treat all three scope types the same way.
    #
    #   M365Group                 -> create/configure a Unified Group (New-RBAC4AppUnifiedGroup)
    #   DistributionList          -> create/configure an EXO-only distribution list
    #                                (New-RBAC4AppDistributionGroup)
    #   MailEnabledSecurityGroup  -> reference-only: on-prem/hybrid-synced groups are mastered
    #                                on-premises and are never created here; only their existence is
    #                                validated (throws if missing).
    #
    # SupportsShouldProcess is intentionally NOT declared here: the create logic lives in the two
    # New-RBACforApp*Group helpers (which do gate on ShouldProcess), and $WhatIfPreference propagates
    # into them automatically. The MailEnabledSecurityGroup branch is read-only.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'State changes are delegated to New-RBAC4AppUnifiedGroup / New-RBAC4AppDistributionGroup, which implement ShouldProcess; $WhatIfPreference propagates into them. The MailEnabledSecurityGroup branch is read-only.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
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

    switch ($AccessGroupType) {
        'M365Group' {
            $params = @{ Name = $Name; ManagedBy = $ManagedBy; BootstrapMember = $BootstrapMember }
            if ($PSBoundParameters.ContainsKey('ChangeReference')) { $params['ChangeReference'] = $ChangeReference }
            return New-RBAC4AppUnifiedGroup @params
        }

        'DistributionList' {
            $params = @{ Name = $Name; ManagedBy = $ManagedBy; BootstrapMember = $BootstrapMember }
            if ($PSBoundParameters.ContainsKey('ChangeReference')) { $params['ChangeReference'] = $ChangeReference }
            return New-RBAC4AppDistributionGroup @params
        }

        'MailEnabledSecurityGroup' {
            Write-Verbose -Message ("Validating existing mail-enabled security group '{0}' (reference-only; not created)." -f $Name)
            $existing = Get-Recipient -Identity $Name -ErrorAction SilentlyContinue
            if (-not $existing) {
                throw "MailEnabledSecurityGroup '$Name' was not found. On-prem/hybrid-synced groups must already exist; this module does not create them. Supply an existing group via -AccessGroupName."
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
                ChangeReference = $ChangeReference
                ChangeReferencePath = $metadataPath
                AlreadyExisted = $true
                Group          = $existing
            }
        }
    }
}
