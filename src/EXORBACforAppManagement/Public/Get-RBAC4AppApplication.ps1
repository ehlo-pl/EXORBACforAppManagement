<#
.SYNOPSIS
Gets one row per application (assignee) holding Exchange Online application-role assignments.

.DESCRIPTION
Get-RBAC4AppApplication is the application-centric inventory view over Get-RBAC4AppEntry: it groups
RBAC4App.Entry rows by assignee (RoleAssigneeType + RoleAssigneeName) and aggregates their roles,
assignment names, scopes, and in-scope recipients onto one RBAC4App.Application row.

Pipe Get-RBAC4AppEntry rows into it (no further Exchange Online reads), or let it fetch them itself
with the same identity and filter parameters Get-RBAC4AppEntry takes.

.PARAMETER InputObject
RBAC4App.Entry rows from Get-RBAC4AppEntry. Other objects are rejected with an error.

.PARAMETER RegisteredAppName
Self-fetch: application display name (see Get-RBAC4AppEntry -RegisteredAppName).

.PARAMETER AppId
Self-fetch: application (client) id. GUID-validated.

.PARAMETER SpObjectId
Self-fetch: service principal object id. GUID-validated.

.PARAMETER Role
Self-fetch: application roles to include (short names such as Mail.Send are normalized).

.PARAMETER Enabled
Self-fetch: only enabled ($true) or disabled ($false) assignments.

.PARAMETER RoleAssigneeType
Self-fetch: assignee type filter; default ServicePrincipal, 'All' for every type.

.PARAMETER ScopeType
Self-fetch: RecipientWriteScope values to include; default Group and CustomRecipientScope, 'All'
for every scope.

.EXAMPLE
Get-RBAC4AppApplication

One row per application holding a group- or custom-scope application-role assignment.

.EXAMPLE
Get-RBAC4AppEntry -Role Mail.Send | Get-RBAC4AppApplication

Groups already-read rows; no further Exchange Online reads.

.EXAMPLE
Get-RBAC4AppApplication -RoleAssigneeType All | Where-Object RoleAssigneeType -ne 'ServicePrincipal'

Lists the non-application assignees (e.g. role groups) holding application roles.

.OUTPUTS
RBAC4App.Application

  DisplayName             - Application display name (null for a non-ServicePrincipal assignee).
  AppId                   - Application (client) id (null when unresolved).
  ServicePrincipalId      - Service principal object id (see Get-RBAC4AppEntry); a warning is added
                            when the rows disagree.
  ExoServicePrincipal     - The raw Exchange Online assignee name.
  RoleAssigneeType        - Assignee type (ServicePrincipal, RoleGroup, ...).
  ManagementScopeNames    - Sorted, unique management scope names.
  ScopeKinds              - Sorted, unique ScopeKind values.
  ScopeGroupNames         - Sorted, unique scope group names.
  ScopeGroupMembers       - Sorted, unique in-scope recipients across every scope.
  Roles                   - Sorted, unique application roles.
  RoleAssignmentNames     - Sorted, unique management role assignment names.
  EffectiveUserNames      - Sorted, unique non-blank raw EffectiveUserName values.
  Apps                    - Sorted, unique non-blank raw App values.
  AssignmentCount         - Number of assignments.
  EnabledAssignmentCount  - Number of enabled assignments.
  DisabledAssignmentCount - Number of disabled assignments.
  Warnings                - Union of the rows' warnings plus aggregation warnings.

.NOTES
Self-fetching requires the same Exchange Online session as Get-RBAC4AppEntry, and reports read
failures the same way.
#>
function Get-RBAC4AppApplication {
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType('RBAC4App.Application')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'FromEntry')]
        [AllowEmptyCollection()]
        [psobject[]] $InputObject,

        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByName')]
        [Alias('DisplayName', 'Name')]
        [ValidateNotNullOrEmpty()]
        [string] $RegisteredAppName,

        [Parameter(Mandatory, ParameterSetName = 'ByAppId')]
        [Alias('ClientId', 'ApplicationId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        [Parameter(Mandatory, ParameterSetName = 'BySpObjectId')]
        [Alias('ObjectId', 'ServicePrincipalId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $SpObjectId,

        [Parameter(ParameterSetName = 'All')]
        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ByAppId')]
        [Parameter(ParameterSetName = 'BySpObjectId')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role,

        [Parameter(ParameterSetName = 'All')]
        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ByAppId')]
        [Parameter(ParameterSetName = 'BySpObjectId')]
        [bool] $Enabled,

        [Parameter(ParameterSetName = 'All')]
        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ByAppId')]
        [Parameter(ParameterSetName = 'BySpObjectId')]
        [ValidateSet('All', 'ServicePrincipal', 'User', 'SecurityGroup', 'RoleGroup', 'RoleAssignmentPolicy', 'ForeignSecurityPrincipal', 'LinkedRoleGroup', 'Computer')]
        [string] $RoleAssigneeType = 'ServicePrincipal',

        [Parameter(ParameterSetName = 'All')]
        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ByAppId')]
        [Parameter(ParameterSetName = 'BySpObjectId')]
        [ValidateSet('All', 'Group', 'CustomRecipientScope', 'Organization', 'MyGAL', 'Self', 'MyDirectReports', 'OU',
            'MyDistributionGroups', 'MyExecutive', 'ExcludedRecipients', 'ExclusiveRecipientScope', 'MailboxICanDelegate', 'AdministrativeUnit',
            'NotApplicable', 'None')]
        [string[]] $ScopeType = @('Group', 'CustomRecipientScope')
    )

    begin {
        $rows = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'FromEntry') {
            foreach ($item in @($InputObject)) {
                if ($null -eq $item) { continue }
                $typeNames = @($item.PSObject.TypeNames)
                if ($typeNames -notcontains 'RBAC4App.Entry' -and $typeNames -notcontains 'Deserialized.RBAC4App.Entry') {
                    Write-Error -Message ("Get-RBAC4AppApplication accepts only Get-RBAC4AppEntry rows (RBAC4App.Entry); got '{0}'." -f $typeNames[0])
                    continue
                }
                $rows.Add($item)
            }
            return
        }

        $fetch = @{}
        foreach ($name in 'RegisteredAppName', 'AppId', 'SpObjectId', 'Role', 'Enabled', 'RoleAssigneeType', 'ScopeType') {
            if ($PSBoundParameters.ContainsKey($name)) { $fetch[$name] = $PSBoundParameters[$name] }
        }
        # Get-RBAC4AppEntry already wrote each row's warnings; they stay on the rows.
        foreach ($row in @(Get-RBAC4AppEntry @fetch)) { $rows.Add($row) }
    }

    end {
        $groups = $rows | Group-Object -Property { '{0}|{1}' -f $_.RoleAssigneeName, $_.RoleAssigneeType } | Sort-Object Name
        $written = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($group in $groups) {
            $app = ConvertTo-RBAC4AppApplicationRow -Entry @($group.Group)
            foreach ($warning in $app.Warnings) {
                # Only aggregation warnings are new here; the rows' own were written by Get-RBAC4AppEntry.
                if (@($group.Group | Where-Object { $_.Warnings -contains $warning }).Count -eq 0 -and $written.Add($warning)) {
                    Write-Warning -Message $warning
                }
            }
            $app
        }
    }
}
