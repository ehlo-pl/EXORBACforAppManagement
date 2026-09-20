<#
.SYNOPSIS
Ensures the Exchange Online service principal pointer for an Entra application exists.

.DESCRIPTION
Register-EXOServicePrincipal ensures the Exchange Online service principal (created via
New-ServicePrincipal) that links an Entra (Azure AD) application registration into Exchange Online
so it can receive application RBAC role assignments exists. Exchange treats this object as a
pointer to the existing Entra service principal.

Existence is checked first (matched by AppId, then by DisplayName, mirroring how callers resolve
it): if a matching EXO service principal already exists, creation is skipped, a warning is written,
and the existing object is returned - New-ServicePrincipal is never called against an AppId that
already has one. This makes the function safe to call unconditionally, the same way
New-RBAC4AppUnifiedGroup/New-RBAC4AppDistributionGroup are.

The function supports -WhatIf and -Confirm through SupportsShouldProcess.

.PARAMETER AppId
Application (client) id of the Entra application. GUID-validated.

.PARAMETER ObjectId
Object id of the Entra service principal (Enterprise Application object id). GUID-validated.

.PARAMETER DisplayName
Display name for the Exchange Online service principal (e.g. "<App>_SP").

.EXAMPLE
Register-EXOServicePrincipal -AppId '1111...' -ObjectId '2222...' -DisplayName 'Contoso_SP' -WhatIf

Shows the planned Exchange Online service principal creation without making changes.

.OUTPUTS
The existing EXO service principal (when one already matches) or the object returned by
New-ServicePrincipal (when created).

.NOTES
Requires a connected Exchange Online session (Get-ServicePrincipal, New-ServicePrincipal).
Companion to New-RBAC4AppEntry.
#>
function Register-EXOServicePrincipal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('ClientId','ApplicationId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('SpObjectId','Id','ServicePrincipalId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $ObjectId,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayName
    )

    process {
        # --- Skip creation if a matching EXO service principal already exists (by AppId, then
        # DisplayName), so this function is safe to call unconditionally.
        $existing = @(Get-ServicePrincipal -ErrorAction SilentlyContinue) |
            Where-Object { $_ -and (($_.AppId -eq $AppId) -or ($_.DisplayName -eq $DisplayName)) } |
            Select-Object -First 1
        if ($existing) {
            Write-Warning -Message "Exchange Online service principal '$DisplayName' (AppId '$AppId') already exists; skipping creation."
            return $existing
        }

        # Typical usage expects AppId + Enterprise AppObjectId (SP object id).
        if ($PSCmdlet.ShouldProcess("EXO ServicePrincipal for AppId $AppId", "Create/Ensure '$DisplayName'")) {
            $resultNewSP = New-ServicePrincipal -AppId $AppId -ObjectId $ObjectId -DisplayName $DisplayName -ErrorAction 0
            Write-Warning -Message "resultNewSP: $resultNewSP"
            return $resultNewSP
        }
    }
}
