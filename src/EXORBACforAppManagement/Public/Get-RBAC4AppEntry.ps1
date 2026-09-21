<#
.SYNOPSIS
Gets Exchange Online RBAC role assignments for application roles (the roles that
New-RBAC4AppEntry creates), per-assignment or grouped per application.

.DESCRIPTION
Get-RBAC4AppEntry retrieves Exchange Online management role assignments whose role
is an application role (named "Application <permission>", e.g. "Application Mail.Send").
By default it returns one object per matching assignment, scoped the way this module
creates them: group-scoped or custom-recipient-scoped entries. With -ByApplication it
instead returns one object per distinct application, the app-centric inventory view
(formerly the separate Get-RegisteredAppWithPermission function, now a deprecated wrapper
around this switch).

Every row - in either view - resolves the assignee back to its Exchange Online service
principal pointer (Get-ServicePrincipal, matched by exact DisplayName; no Microsoft Graph
session is needed) to expose the application's AppId and ServicePrincipalId, and resolves
its recipient scope to the real scope group name, group type (M365Group, DistributionList,
or MailEnabledSecurityGroup), and current membership - not just the raw EXO scope fields.

You can narrow the results to a specific application (by display name, AppId, or service
principal object id), to specific roles, to an enabled/disabled state, to specific assignee
types, and to specific recipient (write) scopes. Filtering by application is done
client-side because Get-ManagementRoleAssignment has no -App parameter; the resolved
identity is matched against each assignment's RoleAssigneeName and Name.

.PARAMETER RegisteredAppName
Display name of the application / service principal to filter assignments by. This is
matched (via the resolved service principal) against the assignment's assignee and name.

.PARAMETER AppId
Application (client) id of the application to filter by. GUID-validated.

.PARAMETER SpObjectId
Object id of the service principal to filter by. GUID-validated.

.PARAMETER Role
One or more application roles to filter by. Short names such as Mail.Send are accepted
and normalized to "Application Mail.Send".

.PARAMETER Enabled
Return only enabled ($true) or only disabled ($false) assignments. Omit to return both.

.PARAMETER RoleAssigneeType
Filter by the assignment's RoleAssigneeType. Defaults to 'ServicePrincipal' (application
assignments). Use 'All' to return every assignee type within the requested -ScopeType
scopes, or pass a specific type to narrow.

.PARAMETER ScopeType
One or more RecipientWriteScope values to include. Defaults to 'Group' and
'CustomRecipientScope' - the only recipient scopes this module ever creates. Pass 'All' to
see every recipient scope, including e.g. Organization-wide application assignments this
module never makes but a tenant may still have (created manually or by another tool).

.PARAMETER ByApplication
Return one object per distinct application instead of one object per assignment - the
app-centric inventory view. Roles, assignment names, and resolved scope group names/members
across all of that application's matching assignments are aggregated onto a single row.

.EXAMPLE
Get-RBAC4AppEntry

Returns service-principal application role assignments that are group-scoped or use a
custom recipient scope (the default behavior), one row per assignment.

.EXAMPLE
Get-RBAC4AppEntry -ByApplication

Returns one row per distinct registered application that currently holds a supported
application-role assignment.

.EXAMPLE
Get-RBAC4AppEntry -RoleAssigneeType All

Returns application role assignments regardless of assignee type, still limited to
Group / CustomRecipientScope recipient scopes.

.EXAMPLE
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send'

Returns the Application Mail.Send assignments scoped to the resolved Contoso Mail App.

.EXAMPLE
Get-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' | Format-Table Name,Role,Scope

Filters by AppId and formats the key columns.

.EXAMPLE
Get-RBAC4AppEntry -ScopeType All -RoleAssigneeType All

Returns every application-role assignment regardless of recipient scope or assignee type.

.OUTPUTS
PSCustomObject

Per-assignment view (default), one object per matching assignment:

  Name               - Management role assignment name.
  Role               - Full application role name (e.g. "Application Mail.Send").
  RoleAssigneeName   - Raw EXO assignee name (e.g. "Contoso_SP").
  RoleAssigneeType   - Assignee type (ServicePrincipal, RoleGroup, ...).
  DisplayName        - Application display name, "_SP" suffix stripped (best-effort for
                       ServicePrincipal assignees even when the EXO pointer can't be resolved).
  AppId              - Application (client) id, from Get-ServicePrincipal (null when unresolved).
  ServicePrincipalId - Service principal object id, from Get-ServicePrincipal (null when
                       unresolved).
  Scope              - Resolved recipient scope group name (via the private
                       Resolve-RBAC4AppScopeGroupName/Resolve-RBAC4AppScope helpers), not the raw
                       EXO scope fields. Null when the assignment has no group scope.
  ScopeGroupType     - M365Group, DistributionList, or MailEnabledSecurityGroup for a
                       Group-scoped assignment; null otherwise or when the group can't be resolved.
  ScopeMembers       - Sorted, unique members (PrimarySmtpAddress, falling back to Name) of the
                       scope group. Empty for non-Group scopes or an unresolvable group.
  RecipientScope     - Raw RecipientWriteScope value (Group, CustomRecipientScope, ...).
  Enabled            - Whether the assignment is enabled.
  Guid               - Assignment Guid.
  Identity           - Assignment Identity.

Per-application view (-ByApplication), one object per distinct application:

  DisplayName             - Application display name (or the "_SP"-stripped assignee when
                            unresolved).
  AppId                   - Application (client) id (null when unresolved).
  ServicePrincipalId      - Service principal object id (null when unresolved).
  ExoServicePrincipal     - The raw Exchange Online assignee name (e.g. Contoso_SP).
  ScopeGroupNames         - Sorted, unique resolved scope group name(s) across the app's
                            assignments. Empty when an assignment has no group scope or its scope
                            group could not be resolved.
  ScopeGroupMembers       - Sorted, unique members across every resolved scope group in
                            ScopeGroupNames.
  Roles                   - Sorted, unique application roles the app holds.
  RoleAssignmentNames     - Sorted, unique management role assignment names.
  AssignmentCount         - Total matched assignments for the app.
  EnabledAssignmentCount  - Count of those that are enabled.
  DisabledAssignmentCount - Count of those that are disabled.

.NOTES
Requires a connected Exchange Online session only (Get-ManagementRoleAssignment,
Get-ServicePrincipal, Get-UnifiedGroup, Get-UnifiedGroupLinks, Get-DistributionGroup,
Get-DistributionGroupMember). No Microsoft Graph session is needed; the application filter
only matches applications already registered via Register-EXOServicePrincipal,
New-RBAC4AppEntry, or Invoke-RBAC4AppConfig. Companion to New-RBAC4AppEntry.

Performance / behavior notes:
- With no -Role, one unfiltered Get-ManagementRoleAssignment call is made and results are
  filtered client-side to "Application *" roles; with -Role, one query per requested role
  (EXO does the role filtering).
- The EXO service principal directory (Get-ServicePrincipal) is read once per call and matched
  client-side by exact DisplayName against each distinct assignee.
- Scope group resolution (Resolve-RBAC4AppScope) adds up to two read calls
  (Get-UnifiedGroup/Get-DistributionGroup, then Get-UnifiedGroupLinks/Get-DistributionGroupMember)
  per distinct Group-scoped scope name, cached for the duration of the call so a group shared by
  several assignments/applications is only read once.
#>
function Get-RBAC4AppEntry {
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [Alias('DisplayName','Name')]
        [ValidateNotNullOrEmpty()]
        [string] $RegisteredAppName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByAppId')]
        [Alias('ClientId','ApplicationId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'BySpObjectId')]
        [Alias('Id','ObjectId','ServicePrincipalId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $SpObjectId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role,

        [Parameter()]
        [bool] $Enabled,

        [Parameter()]
        [ValidateSet('All','ServicePrincipal','User','SecurityGroup','RoleGroup','RoleAssignmentPolicy','ForeignSecurityPrincipal','LinkedRoleGroup','Computer')]
        [string] $RoleAssigneeType = 'ServicePrincipal',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $ScopeType = @('Group', 'CustomRecipientScope'),

        [Parameter()]
        [switch] $ByApplication
    )

    process {
        # --- Resolve the service principal when an application filter is requested.
        $sp = $null
        try {
            switch ($PSCmdlet.ParameterSetName) {
                'BySpObjectId' { $sp = Resolve-RBAC4AppServicePrincipal -SpObjectId $SpObjectId }
                'ByAppId'      { $sp = Resolve-RBAC4AppServicePrincipal -AppId $AppId }
                'ByName'       { $sp = Resolve-RBAC4AppServicePrincipal -DisplayName $RegisteredAppName }
            }
            if ($PSCmdlet.ParameterSetName -ne 'All' -and -not $sp) {
                throw "No Exchange Online service principal found matching the supplied identity. It must already be registered via Register-EXOServicePrincipal, New-RBAC4AppEntry, or Invoke-RBAC4AppConfig."
            }
        }
        catch {
            Write-Error -Message $_.Exception.Message
            return
        }

        # --- Retrieve assignments, filtered by role where possible.
        $rolesNormalized = if ($PSBoundParameters.ContainsKey('Role')) { @($Role | ForEach-Object { ConvertTo-AppRole $_ } | Select-Object -Unique) } else { @() }

        $assignments =
            if ($rolesNormalized.Count -gt 0) {
                # Query per requested role so EXO does the role filtering for us.
                foreach ($r in $rolesNormalized) {
                    Get-ManagementRoleAssignment -Role $r -ErrorAction SilentlyContinue
                }
            }
            else {
                # No role filter: get everything and keep only application roles.
                Get-ManagementRoleAssignment -ErrorAction SilentlyContinue |
                    Where-Object { $_.Role -like 'Application *' }
            }

        # --- Optional enabled-state filter.
        if ($PSBoundParameters.ContainsKey('Enabled')) {
            $assignments = $assignments | Where-Object { $_.Enabled -eq $Enabled }
        }

        # --- Recipient (write) scope filter. Defaults to the scopes this module creates (Group,
        # CustomRecipientScope); pass -ScopeType All to see every recipient scope.
        if ($ScopeType -notcontains 'All') {
            $assignments = $assignments | Where-Object { [string]$_.RecipientWriteScope -in $ScopeType }
        }

        # --- Assignee-type filter (default: ServicePrincipal; 'All' returns every type).
        if ($RoleAssigneeType -ne 'All') {
            $assignments = $assignments | Where-Object { $_.RoleAssigneeType -eq $RoleAssigneeType }
        }

        # --- Optional application filter (client-side: Get-ManagementRoleAssignment has no -App).
        if ($sp) {
            $needles = @($sp.DisplayName, ("{0}_SP" -f $sp.DisplayName), $sp.AppId, $sp.Id) | Where-Object { $_ }
            $assignments = $assignments | Where-Object {
                $assignee = [string]$_.RoleAssigneeName
                $name     = [string]$_.Name
                $hit = $false
                foreach ($n in $needles) {
                    if (($assignee -and $assignee -like "*$n*") -or ($name -and $name -like "*$n*")) { $hit = $true; break }
                }
                $hit
            }
        }

        $assignments = @($assignments | Where-Object { $_ })
        if ($assignments.Count -eq 0) { return }

        # --- Resolve every distinct assignee to its Exchange Online service principal pointer
        # (Get-ServicePrincipal), read once per call - gives AppId/ServicePrincipalId with no
        # Microsoft Graph session needed. Matched by exact DisplayName, the same both-forms rule
        # Resolve-RBAC4AppServicePrincipal uses (the pointer's own DisplayName carries "_SP").
        $allExoServicePrincipals = @(Get-ServicePrincipal -ErrorAction SilentlyContinue)
        $spByAssignee = @{}
        $warnedAssignees = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($a in $assignments) {
            $assigneeName = [string]$a.RoleAssigneeName
            if ($spByAssignee.ContainsKey($assigneeName)) { continue }

            $resolved = $allExoServicePrincipals | Where-Object { $_ -and ([string]$_.DisplayName -eq $assigneeName) } | Select-Object -First 1
            $spByAssignee[$assigneeName] = $resolved

            if (-not $resolved -and $a.RoleAssigneeType -eq 'ServicePrincipal' -and $warnedAssignees.Add($assigneeName)) {
                Write-Warning -Message ("Could not resolve EXO assignee '{0}' to an Exchange Online service principal; AppId/ServicePrincipalId will be empty." -f $assigneeName)
            }
        }

        # --- Scope resolution, cached per distinct scope group name for the duration of the call.
        $scopeCache = @{}

        function Get-DisplayNameFor([string] $assigneeName, [object] $resolvedSp, [string] $roleAssigneeType) {
            if ($resolvedSp) { return [string]$resolvedSp.DisplayName -replace '_SP$', '' }
            if ($roleAssigneeType -eq 'ServicePrincipal') { return ($assigneeName -replace '_SP$', '') }
            return $null
        }

        if ($ByApplication) {
            foreach ($assignmentGroup in ($assignments | Group-Object RoleAssigneeName | Sort-Object Name)) {
                $assigneeName = [string]$assignmentGroup.Name
                $resolvedSp = $spByAssignee[$assigneeName]

                $rolesForApp = @($assignmentGroup.Group.Role | Sort-Object -Unique)
                $assignmentNames = @($assignmentGroup.Group.Name | Sort-Object -Unique)

                $scopes = @($assignmentGroup.Group | ForEach-Object { Resolve-RBAC4AppScope -Assignment $_ -Cache $scopeCache })
                $scopeNames = @($scopes | Where-Object { $_.ScopeName } | ForEach-Object { $_.ScopeName } | Sort-Object -Unique)
                $scopeMembers = @($scopes | ForEach-Object { $_.Members } | Where-Object { $_ } | Sort-Object -Unique)

                [pscustomobject][ordered]@{
                    DisplayName             = Get-DisplayNameFor $assigneeName $resolvedSp 'ServicePrincipal'
                    AppId                   = if ($resolvedSp) { [string]$resolvedSp.AppId } else { $null }
                    ServicePrincipalId      = if ($resolvedSp) { [string]$resolvedSp.ObjectId } else { $null }
                    ExoServicePrincipal     = $assigneeName
                    ScopeGroupNames         = $scopeNames
                    ScopeGroupMembers       = $scopeMembers
                    Roles                   = $rolesForApp
                    RoleAssignmentNames     = $assignmentNames
                    AssignmentCount         = $assignmentGroup.Count
                    EnabledAssignmentCount  = @($assignmentGroup.Group | Where-Object { $_.Enabled }).Count
                    DisabledAssignmentCount = @($assignmentGroup.Group | Where-Object { -not $_.Enabled }).Count
                }
            }
            return
        }

        foreach ($a in $assignments) {
            $assigneeName = [string]$a.RoleAssigneeName
            $resolvedSp = $spByAssignee[$assigneeName]
            $scope = Resolve-RBAC4AppScope -Assignment $a -Cache $scopeCache

            [pscustomobject][ordered]@{
                Name               = $a.Name
                Role               = $a.Role
                RoleAssigneeName   = $a.RoleAssigneeName
                RoleAssigneeType   = $a.RoleAssigneeType
                DisplayName        = Get-DisplayNameFor $assigneeName $resolvedSp $a.RoleAssigneeType
                AppId              = if ($resolvedSp) { [string]$resolvedSp.AppId } else { $null }
                ServicePrincipalId = if ($resolvedSp) { [string]$resolvedSp.ObjectId } else { $null }
                Scope              = $scope.ScopeName
                ScopeGroupType     = $scope.ScopeGroupType
                ScopeMembers       = $scope.Members
                RecipientScope     = $a.RecipientWriteScope
                Enabled            = $a.Enabled
                Guid               = $a.Guid
                Identity           = $a.Identity
            }
        }
    }
}
