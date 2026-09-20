<#
.SYNOPSIS
Lists registered applications that hold Exchange Online application RBAC permissions.

.DESCRIPTION
Get-RegisteredAppWithPermission returns one object per distinct Entra service principal
that has one or more Exchange Online management role assignments for application roles.
It is the app-centric (one row per application) inventory counterpart to Get-RBAC4AppEntry,
which is assignment-centric. Unlike the New-/Get-RBAC4AppEntry functions it has no
ByName/ByAppId/BySpObjectId parameter sets: it performs a tenant-wide sweep rather than a
single-application lookup.

Processing steps:

  1. Decide which roles to query. With -Role, the supplied short names (e.g. Mail.Send) are
     normalized to their full names (Application Mail.Send) via Get-NormalizeRole and deduped.
     Without -Role, every role supported by New-RBAC4AppEntry is queried (the keys of the
     shared Get-AppRoleMap table).
  2. Query Exchange Online once per role via Get-ManagementRoleAssignment -Role (EXO does the
     role filtering). Roles with no assignments simply contribute nothing.
  3. Keep only application assignments to service principals (Role -like 'Application *' and
     RoleAssigneeType -eq 'ServicePrincipal').
  4. Apply the optional -Enabled filter.
  5. Group the surviving assignments by RoleAssigneeName (this collapses many assignments into
     one row per application) and resolve each distinct assignee back to its Exchange Online
     service principal pointer (Get-ServicePrincipal), matched by exact DisplayName - the EXO
     assignee IS that pointer's own DisplayName (e.g. "Contoso_SP"), so no Microsoft Graph lookup
     is needed. The exposed DisplayName is normalized back to the application name (the "_SP"
     suffix stripped). No match falls back to EXO-only details for that application.
  6. Resolve each distinct scope group referenced by the app's assignments and read its
     membership. The scope group identity is NOT read directly off CustomRecipientWriteScope: for
     the 'Group' write-scope that every assignment made by this module actually uses,
     CustomRecipientWriteScope is empty on a real tenant, and the group name has to be recovered
     from CustomResourceScope (the name of an auto-created ManagementScope object, which follows
     the pattern "<GroupName>_<GUID>") - see the private Resolve-RBAC4AppScopeGroupName helper.
     Once the group name is resolved, Get-UnifiedGroup is tried first (M365Group), then
     Get-DistributionGroup (DistributionList or MailEnabledSecurityGroup); a scope group resolved
     by neither is skipped with a warning. Resolved scope groups are cached per run so a group
     referenced by multiple applications is only read once.
  7. Emit one object per application. When the EXO service principal pointer cannot be resolved
     (e.g. it was removed after the role assignment was made) the row is still returned with
     EXO-only details (DisplayName falls back to the assignee with "_SP" stripped; AppId and
     ServicePrincipalId are null) and a warning is written.

No Microsoft Graph session is required or used; every application is resolved through Exchange
Online's own service principal pointers (Get-ServicePrincipal).

.PARAMETER Role
One or more application roles to query. Short names such as Mail.Send are accepted and
normalized to Application Mail.Send. When omitted, every role supported by
New-RBAC4AppEntry is queried.

.PARAMETER Enabled
Return only enabled ($true) or only disabled ($false) assignments. Omit to return both.

.EXAMPLE
Get-RegisteredAppWithPermission

Returns every registered application that currently has one or more supported
application-role assignments.

.EXAMPLE
Get-RegisteredAppWithPermission -Role 'Mail.Send'

Returns the registered applications that hold the Application Mail.Send role.

.OUTPUTS
PSCustomObject

One object per distinct registered application, with the following properties:

  DisplayName             - Application display name (or the "_SP"-stripped assignee when
                            unresolved).
  AppId                   - Application (client) id (null when unresolved).
  ServicePrincipalId      - Service principal object id (null when unresolved).
  ExoServicePrincipal     - The raw Exchange Online assignee name (e.g. Contoso_SP).
  ScopeGroupNames         - Sorted, unique recipient scope group name(s) the app's assignments are
                            scoped to (resolved via the private Resolve-RBAC4AppScopeGroupName
                            helper, not read directly off CustomRecipientWriteScope). Empty when an
                            assignment has no group scope (e.g. Organization-wide) or its scope
                            group could not be resolved.
  ScopeGroupMembers       - Sorted, unique members (PrimarySmtpAddress, falling back to Name) across
                            every resolved scope group in ScopeGroupNames. A scope group that could
                            not be resolved via Get-UnifiedGroup or Get-DistributionGroup contributes
                            nothing here; a warning is written to the warning stream instead.
  Roles                   - Sorted, unique application roles the app holds.
  RoleAssignmentNames     - Sorted, unique management role assignment names.
  AssignmentCount         - Total matched assignments for the app.
  EnabledAssignmentCount  - Count of those that are enabled.
  DisabledAssignmentCount - Count of those that are disabled.

.NOTES
Requires a connected Exchange Online session only (Get-ManagementRoleAssignment,
Get-ServicePrincipal, Get-UnifiedGroup, Get-UnifiedGroupLinks, Get-DistributionGroup,
Get-DistributionGroupMember). No Microsoft Graph session is needed.

Performance / behavior notes:
- The function issues one Get-ManagementRoleAssignment query per role, so cost scales with the
  number of roles requested (all supported roles by default); EXO does the filtering and results
  are grouped client-side.
- The EXO service principal list (Get-ServicePrincipal) is read once per call and matched
  client-side by exact DisplayName against each assignee.
- Unlike Get-RBAC4AppEntry, this function does not filter on recipient scope: any
  'Application *' assignment to a service principal is counted.
- Scope group resolution adds up to two read calls (Get-UnifiedGroup/Get-DistributionGroup, then
  Get-UnifiedGroupLinks/Get-DistributionGroupMember) per distinct scope group name, cached for the
  duration of the call so a group shared by several applications is only read once.
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
        $supportedRoleMap = Get-AppRoleMap
        $rolesNormalized =
            if ($PSBoundParameters.ContainsKey('Role')) {
                @($Role | ForEach-Object { Get-NormalizeRole $_ } | Select-Object -Unique)
            }
            else {
                @($supportedRoleMap.Keys)
            }

        $assignments = foreach ($roleItem in $rolesNormalized) {
            Get-ManagementRoleAssignment -Role $roleItem -ErrorAction SilentlyContinue
        }

        $assignments = @(
            $assignments |
                Where-Object {
                    $_ -and
                    $_.Role -like 'Application *' -and
                    $_.RoleAssigneeType -eq 'ServicePrincipal'
                }
        )

        if ($PSBoundParameters.ContainsKey('Enabled')) {
            $assignments = @($assignments | Where-Object { $_.Enabled -eq $Enabled })
        }

        # --- Read the Exchange Online service principal directory once per call; each application
        # is resolved against it by exact DisplayName below, no Microsoft Graph session needed.
        $allExoServicePrincipals = @(Get-ServicePrincipal -ErrorAction SilentlyContinue)

        # --- Scope group membership is cached once per run: the same group can back more than one
        # application's assignments, and re-reading it per application would be wasteful. Scope
        # group *names* aren't cached - resolving one is a pure string parse, no EXO round trip.
        $scopeGroupMemberCache = @{}

        foreach ($assignmentGroup in ($assignments | Group-Object RoleAssigneeName | Sort-Object Name)) {
            $assigneeName = [string]$assignmentGroup.Name
            $resolvedSp = $allExoServicePrincipals |
                Where-Object { $_ -and ([string]$_.DisplayName -eq $assigneeName) } |
                Select-Object -First 1

            if (-not $resolvedSp) {
                Write-Warning -Message ("Could not resolve EXO assignee '{0}' to an Exchange Online service principal; returning EXO-only details." -f $assigneeName)
            }

            $rolesForApp = @($assignmentGroup.Group.Role | Sort-Object -Unique)
            $assignmentNames = @($assignmentGroup.Group.Name | Sort-Object -Unique)

            # --- Scope group name(s): the recipient scope each assignment is bound to. Resolved
            # per-assignment via the shared helper (not read directly off CustomRecipientWriteScope,
            # which is empty for the 'Group' write-scope every assignment here actually uses).
            $scopeNames = @(
                $assignmentGroup.Group |
                    ForEach-Object { Resolve-RBAC4AppScopeGroupName -Assignment $_ } |
                    Where-Object { $_ } |
                    Sort-Object -Unique
            )

            # --- Scope group content: resolve (and cache) each scope group's membership.
            $scopeMembers = foreach ($scopeName in $scopeNames) {
                if (-not $scopeGroupMemberCache.ContainsKey($scopeName)) {
                    $links = $null
                    if (Get-UnifiedGroup -Identity $scopeName -ErrorAction SilentlyContinue) {
                        $links = @(Get-UnifiedGroupLinks -Identity $scopeName -LinkType Members -ErrorAction SilentlyContinue)
                    }
                    elseif (Get-DistributionGroup -Identity $scopeName -ErrorAction SilentlyContinue) {
                        $links = @(Get-DistributionGroupMember -Identity $scopeName -ErrorAction SilentlyContinue)
                    }
                    else {
                        Write-Warning -Message ("Could not resolve scope group '{0}' via Get-UnifiedGroup or Get-DistributionGroup; its membership will be omitted." -f $scopeName)
                    }

                    $scopeGroupMemberCache[$scopeName] = @($links | ForEach-Object {
                            if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
                        } | Where-Object { $_ } | Select-Object -Unique)
                }

                $scopeGroupMemberCache[$scopeName]
            }
            $scopeMembers = @($scopeMembers | Sort-Object -Unique)

            [pscustomobject][ordered]@{
                DisplayName           = if ($resolvedSp) { [string]$resolvedSp.DisplayName -replace '_SP$', '' } else { ($assigneeName -replace '_SP$', '') }
                AppId                 = if ($resolvedSp) { [string]$resolvedSp.AppId } else { $null }
                ServicePrincipalId    = if ($resolvedSp) { [string]$resolvedSp.ObjectId } else { $null }
                ExoServicePrincipal   = $assigneeName
                ScopeGroupNames       = $scopeNames
                ScopeGroupMembers     = $scopeMembers
                Roles                 = $rolesForApp
                RoleAssignmentNames   = $assignmentNames
                AssignmentCount       = $assignmentGroup.Count
                EnabledAssignmentCount = @($assignmentGroup.Group | Where-Object { $_.Enabled }).Count
                DisabledAssignmentCount = @($assignmentGroup.Group | Where-Object { -not $_.Enabled }).Count
            }
        }
    }
}
