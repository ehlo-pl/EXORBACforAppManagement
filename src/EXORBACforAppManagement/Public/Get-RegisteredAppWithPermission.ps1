<#
.SYNOPSIS
Deprecated. Lists registered applications that hold Exchange Online application RBAC
permissions - use Get-RBAC4AppEntry -ByApplication instead.

.DESCRIPTION
Get-RegisteredAppWithPermission is now a thin backward-compatible wrapper around
Get-RBAC4AppEntry -ByApplication -ScopeType All (the app-centric inventory view merged into
Get-RBAC4AppEntry). It is kept so existing scripts keep working, and will be removed in a
future release - update scripts to call Get-RBAC4AppEntry -ByApplication directly, which
also exposes per-assignment detail, resolved scope group type, and additional filters
(-RoleAssigneeType, -ScopeType) this wrapper does not expose.

-ScopeType All is passed through to preserve this function's original behavior: unlike
Get-RBAC4AppEntry's own default, it never filtered on recipient scope, counting any
"Application *" assignment to a service principal regardless of scope.

.PARAMETER Role
One or more application roles to query. Short names such as Mail.Send are accepted and
normalized to Application Mail.Send. When omitted, every application role is queried.

.PARAMETER Enabled
Return only enabled ($true) or only disabled ($false) assignments. Omit to return both.

.EXAMPLE
Get-RegisteredAppWithPermission

Returns every registered application that currently has one or more supported
application-role assignments. Equivalent to Get-RBAC4AppEntry -ByApplication -ScopeType All.

.OUTPUTS
PSCustomObject

See Get-RBAC4AppEntry -ByApplication's .OUTPUTS for the returned shape.

.NOTES
Requires a connected Exchange Online session only. No Microsoft Graph session is needed.
Deprecated: use Get-RBAC4AppEntry -ByApplication instead.
#>
function Get-RegisteredAppWithPermission {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role,

        [Parameter()]
        [bool] $Enabled
    )

    process {
        Write-Warning -Message 'Get-RegisteredAppWithPermission is deprecated and will be removed in a future release. Use Get-RBAC4AppEntry -ByApplication instead.'

        $params = @{
            ByApplication = $true
            ScopeType     = 'All'
        }
        if ($PSBoundParameters.ContainsKey('Role')) { $params.Role = $Role }
        if ($PSBoundParameters.ContainsKey('Enabled')) { $params.Enabled = $Enabled }

        Get-RBAC4AppEntry @params
    }
}
