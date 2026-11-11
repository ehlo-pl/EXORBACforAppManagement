function New-RBAC4AppManagementScope {
    <#
    .SYNOPSIS
        Ensures an Exchange Online management scope exists with a given recipient restriction filter.

    .DESCRIPTION
        Idempotent wrapper around Get-/New-/Set-ManagementScope used to back RBAC for Applications
        role assignments (New-ManagementRoleAssignment -CustomResourceScope). When the scope does
        not exist it is created with -RecipientRestrictionFilter. When it exists and its filter
        differs (compared loosely: case, whitespace and parentheses are ignored, since Exchange
        Online re-renders stored filters) it is updated with Set-ManagementScope, unless -NoUpdate
        is supplied, in which case the drift is only reported as a warning.

        Scopes are never created as exclusive: exclusive scopes do not restrict application access.
        Permission changes can take 30 minutes to 2 hours to take effect (Exchange Online caching).

    .PARAMETER Name
        Management scope name (max 64 characters).

    .PARAMETER RecipientRestrictionFilter
        OPATH recipient filter, e.g. "MemberOfGroup -eq '<group DN>'",
        "PrimarySmtpAddress -eq 'user@contoso.com'", or "CustomAttribute1 -eq 'AppX'".

    .PARAMETER NoUpdate
        Do not change an existing scope's filter; only warn when it differs.

    .EXAMPLE
        New-RBAC4AppManagementScope -Name 'MSRAo1P-Contoso' -RecipientRestrictionFilter "CustomAttribute1 -eq 'Contoso'" -WhatIf

    .OUTPUTS
        [pscustomobject] with Name, RecipientRestrictionFilter, PreviousFilter, AlreadyExisted,
        Created, FilterUpdated, and Scope.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 64)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RecipientRestrictionFilter,

        [Parameter()]
        [switch] $NoUpdate
    )

    $result = [ordered]@{
        Name                       = $Name
        RecipientRestrictionFilter = $RecipientRestrictionFilter
        PreviousFilter             = $null
        AlreadyExisted             = $false
        Created                    = $false
        FilterUpdated              = $false
        Scope                      = $null
    }

    $existing = Get-ManagementScope -Identity $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($existing) {
        $result.AlreadyExisted = $true
        $result.Scope = $existing
        $current = [string]$existing.RecipientFilter
        $result.PreviousFilter = $current

        if (-not (Test-RBAC4AppRecipientFilterEqual -Reference $current -Difference $RecipientRestrictionFilter)) {
            if ($NoUpdate) {
                Write-Warning -Message ("Management scope '{0}' already exists with a different filter (current: {1}; requested: {2}). Left unchanged; use Set-RBAC4AppEntry to update it." -f $Name, $current, $RecipientRestrictionFilter)
                $result.RecipientRestrictionFilter = $current
            }
            elseif ($PSCmdlet.ShouldProcess($Name, "Set-ManagementScope -RecipientRestrictionFilter `"$RecipientRestrictionFilter`"")) {
                Set-ManagementScope -Identity $Name -RecipientRestrictionFilter $RecipientRestrictionFilter -ErrorAction Stop | Out-Null
                $result.FilterUpdated = $true
                Write-Verbose -Message ("Updated management scope '{0}' filter." -f $Name)
            }
        }
        else {
            Write-Verbose -Message ("Management scope '{0}' already exists with the requested filter." -f $Name)
        }
    }
    elseif ($PSCmdlet.ShouldProcess($Name, "New-ManagementScope -RecipientRestrictionFilter `"$RecipientRestrictionFilter`"")) {
        $result.Scope = New-ManagementScope -Name $Name -RecipientRestrictionFilter $RecipientRestrictionFilter -ErrorAction Stop
        $result.Created = $true
        Write-Verbose -Message ("Created management scope '{0}'." -f $Name)
    }

    [pscustomobject]$result
}
