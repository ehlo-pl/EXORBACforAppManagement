<#
.SYNOPSIS
Gets application role assignments for Exchange Online service principals.

.DESCRIPTION
Returns application-role assignments assigned to service principals, including the
assignment fields and recipient scope properties. App and RoleAssigneeName are resolved
to the application display name, and CustomResourceScope is resolved to the in-scope
recipients' primary SMTP addresses where available.

.OUTPUTS
PSCustomObject

.NOTES
Requires a connected Exchange Online session. No Microsoft Graph session is needed.
#>
function Get-EXORBACforAppRoleAssignment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    process {
        $assignments = @(Get-ManagementRoleAssignment -ErrorAction SilentlyContinue |
                Where-Object { $_.Role -imatch '^Application' -and $_.RoleAssigneeType -imatch 'ServicePrincipal' } |
                Sort-Object RoleAssigneeType)
        if ($assignments.Count -eq 0) { return }

        $servicePrincipals = @(Get-ServicePrincipal -ErrorAction SilentlyContinue)
        $scopeCache = @{}
        $resolveDisplayName = {
            param($Identity)

            if ($null -eq $Identity) { return $null }
            $identityName = if ($Identity.PSObject.Properties['DisplayName']) {
                [string]$Identity.DisplayName
            }
            else {
                [string]$Identity
            }
            if (-not $identityName) { return $null }

            $resolved = $servicePrincipals | Where-Object {
                $displayName = [string]$_.DisplayName
                $identityName -eq $displayName -or
                $identityName -eq ($displayName -replace '_SP$', '') -or
                $identityName -eq [string]$_.AppId -or
                $identityName -eq [string]$_.ObjectId
            } | Select-Object -First 1

            if ($resolved) { return ([string]$resolved.DisplayName -replace '_SP$', '') }
            return ($identityName -replace '_SP$', '')
        }

        foreach ($assignment in $assignments) {
            $scope = Resolve-RBAC4AppScope -Assignment $assignment -Cache $scopeCache
            $result = [ordered]@{
                Name               = $assignment.Name
                Role               = $assignment.Role
                RoleAssigneeName   = & $resolveDisplayName $assignment.RoleAssigneeName
                RoleAssigneeType   = $assignment.RoleAssigneeType
                AssignmentMethod   = $assignment.AssignmentMethod
                EffectiveUserName  = $assignment.EffectiveUserName
                App                = & $resolveDisplayName $assignment.App
                CustomResourceScope = @($scope.Members)
            }

            foreach ($property in $assignment.PSObject.Properties | Where-Object Name -Like 'Recipient*') {
                $result[$property.Name] = $property.Value
            }

            [pscustomobject]$result
        }
    }
}
