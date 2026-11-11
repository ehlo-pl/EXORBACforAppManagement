<#
.SYNOPSIS
Gets Exchange Online RBAC role assignments for application roles (the roles that
New-RBAC4AppEntry creates), one enriched row per assignment.

.DESCRIPTION
Get-RBAC4AppEntry retrieves Exchange Online management role assignments whose role is an
application role (named "Application <permission>", e.g. "Application Mail.Send") and returns one
RBAC4App.Entry row per matching assignment. It is a pure read: it writes no files and changes
nothing.

Every row resolves the assignee back to its Exchange Online service principal pointer
(Get-ServicePrincipal; no Microsoft Graph session is needed) and its recipient scope to the real
scope group name, group type (M365Group, DistributionList, or MailEnabledSecurityGroup) and
membership, or to the management scope's kind, filter, and in-scope recipients.

Related functions consume these rows from the pipeline without reading Exchange Online again:
  Get-RBAC4AppEntry | Get-RBAC4AppApplication     # one row per application
  Get-RBAC4AppEntry | Export-RBAC4AppConfig       # Invoke-RBAC4AppConfig config files

Exchange Online is read once per call, however many identities are piped in: one
Get-ServicePrincipal directory read and one Get-ManagementRoleAssignment read (one per role with
-Role), plus scope reads cached per distinct scope or group. A failed read is an error, not an
empty result (see NOTES).

.PARAMETER RegisteredAppName
Display name of the application to return assignments for. Matches the Exchange Online service
principal pointer's DisplayName with or without its "_SP" suffix. Accepts strings from the
pipeline.

.PARAMETER AppId
Application (client) id of the application to return assignments for. GUID-validated. Binds by
property name from the pipeline, so a Get-RBAC4AppEntry row, a New-RegisteredApp result, or any
object with an AppId property pipes in.

.PARAMETER SpObjectId
Object id of the service principal to return assignments for. GUID-validated. Not bound from the
pipeline (pass it explicitly).

.PARAMETER Role
One or more application roles to filter by. Short names such as Mail.Send are accepted and
normalized to "Application Mail.Send".

.PARAMETER Enabled
Return only enabled ($true) or only disabled ($false) assignments. Omit to return both.

.PARAMETER RoleAssigneeType
Filter by the assignment's RoleAssigneeType. Defaults to 'ServicePrincipal' (application
assignments). Use 'All' to return every assignee type within the requested -ScopeType scopes.

.PARAMETER ScopeType
One or more RecipientWriteScope values to include. Defaults to 'Group' and 'CustomRecipientScope',
the only recipient scopes this module creates. Pass 'All' to see every recipient scope, including
e.g. Organization-wide application assignments made by hand or by another tool.

.EXAMPLE
Get-RBAC4AppEntry

Returns the service-principal application role assignments that are group-scoped or use a custom
recipient scope, one row per assignment.

.EXAMPLE
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send'

Returns the Application Mail.Send assignments of the Contoso Mail App.

.EXAMPLE
'Contoso Mail App', 'Fabrikam Archiver' | Get-RBAC4AppEntry

Returns the assignments of both applications, reading Exchange Online once.

.EXAMPLE
Get-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' | Format-Table Name, Role, Scope

Filters by AppId and formats the key columns.

.EXAMPLE
Get-RBAC4AppEntry -ScopeType All -RoleAssigneeType All

Returns every application-role assignment regardless of recipient scope or assignee type.

.EXAMPLE
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' | Export-RBAC4AppConfig -Format Json

Exports each of the application's assignments as a JSON config for Invoke-RBAC4AppConfig.

.OUTPUTS
RBAC4App.Entry

One object per matching assignment:

  Name                     - Management role assignment name.
  RoleAssignmentName       - Same as Name.
  Role                     - Full application role name (e.g. "Application Mail.Send").
  RoleAssigneeName         - Raw EXO assignee name (a service principal object id, or e.g. "Contoso_SP").
  RoleAssigneeType         - Assignee type (ServicePrincipal, RoleGroup, ...).
  EffectiveUserName        - Raw EffectiveUserName from Get-ManagementRoleAssignment, as-is.
  App                      - Raw App from Get-ManagementRoleAssignment, as-is.
  DisplayName              - Application display name, "_SP" suffix stripped; for an unresolved
                             ServicePrincipal assignee, the assignee name; null for other assignee types.
  AppId                    - Application (client) id from the EXO pointer (null when unresolved).
  ServicePrincipalId       - Service principal object id: the pointer's ObjectId, otherwise (for
                             ServicePrincipal assignees) the GUID in EffectiveUserName, with a warning.
  ServicePrincipalIdSource - Where ServicePrincipalId came from: ExoPointer, EffectiveUserName,
                             NameHeuristic (the pointer was matched by the generated assignment name
                             only; Export-RBAC4AppConfig refuses it without -Force), or None.
  Scope                    - The scope group name for a group-based scope, otherwise the
                             management scope name; null when the assignment has no recipient scope.
  ScopeSource              - ManagementScope (bound via -CustomResourceScope), Legacy (bound directly
                             to a group), or None.
  ManagementScope          - Management scope name; null for legacy group-bound assignments.
  ScopeKind                - Group, Recipients, Tag, or Filter (from the management scope's filter);
                             GroupDirect for a legacy group-bound assignment; null when the
                             management scope could not be read.
  ScopeFilter              - The management scope's RecipientFilter (null for GroupDirect).
  ScopeGroupName           - The scope group name for Group/GroupDirect scopes, otherwise null.
  ScopeGroupType           - M365Group, DistributionList, or MailEnabledSecurityGroup; null when not a
                             group scope or the group could not be read.
  ScopeGroupResolved       - $true when a Group/GroupDirect scope group was actually read.
  ScopeMembers             - Sorted, unique in-scope recipients (PrimarySmtpAddress, falling back to
                             Name): group members, the Recipients list, or - for Tag/Filter - a
                             Get-Recipient -RecipientPreviewFilter preview capped at 1000.
  RecipientScope           - Raw RecipientWriteScope value (Group, CustomRecipientScope, ...).
  Enabled, Guid, Identity  - From the assignment.
  Warnings                 - The warnings that apply to this row (also written once per call).
  Errors                   - Reserved; always empty.

.NOTES
Requires a connected Exchange Online session only (Get-ManagementRoleAssignment,
Get-ServicePrincipal, Get-ManagementScope, Get-Recipient, Get-UnifiedGroup, Get-UnifiedGroupLinks,
Get-DistributionGroup, Get-DistributionGroupMember). The application filter only matches
applications already registered via Register-EXOServicePrincipal, New-RBAC4AppEntry, or
Invoke-RBAC4AppConfig.

Errors:
- An identity that matches no service principal (or several) is a non-terminating error for that
  pipeline item; the next item is still processed.
- A failed Get-ServicePrincipal or Get-ManagementRoleAssignment read is one non-terminating error
  per call; nothing is returned and later pipeline items are skipped without retrying.

Filtering by application is exact: an assignment is kept when its resolved assignee is the same
service principal (object id, or AppId when an object id is missing) - never by name substring.
#>
function Get-RBAC4AppEntry {
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType('RBAC4App.Entry')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByName')]
        [Alias('DisplayName', 'Name')]
        [ValidateNotNullOrEmpty()]
        [string] $RegisteredAppName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByAppId')]
        [Alias('ClientId', 'ApplicationId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        [Parameter(Mandatory, ParameterSetName = 'BySpObjectId')]
        [Alias('ObjectId', 'ServicePrincipalId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $SpObjectId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role,

        [Parameter()]
        [bool] $Enabled,

        [Parameter()]
        [ValidateSet('All', 'ServicePrincipal', 'User', 'SecurityGroup', 'RoleGroup', 'RoleAssignmentPolicy', 'ForeignSecurityPrincipal', 'LinkedRoleGroup', 'Computer')]
        [string] $RoleAssigneeType = 'ServicePrincipal',

        [Parameter()]
        [ValidateSet('All', 'Group', 'CustomRecipientScope', 'Organization', 'MyGAL', 'Self', 'MyDirectReports', 'OU',
            'MyDistributionGroups', 'MyExecutive', 'ExcludedRecipients', 'ExclusiveRecipientScope', 'MailboxICanDelegate', 'AdministrativeUnit',
            'NotApplicable', 'None')]
        [string[]] $ScopeType = @('Group', 'CustomRecipientScope')
    )

    begin {
        $setFilter = @{
            Role             = if ($PSBoundParameters.ContainsKey('Role')) { @($Role | ForEach-Object { ConvertTo-RBAC4AppRoleName -Role $_ } | Select-Object -Unique) } else { @() }
            Enabled          = if ($PSBoundParameters.ContainsKey('Enabled')) { $Enabled } else { $null }
            ScopeType        = $ScopeType
            RoleAssigneeType = $RoleAssigneeType
        }
        # Shared by every pipeline item: Exchange Online is read lazily, once per call (F1).
        $state = [pscustomobject]@{
            Failed        = $false
            Index         = $null
            Assignments   = $null
            AssigneeCache = @{}
            ScopeCache    = @{}
            Warned        = [System.Collections.Generic.HashSet[string]]::new()
        }
    }

    process {
        if ($state.Failed) { return }

        if (-not $state.Index) {
            try { $state.Index = Get-RBAC4AppServicePrincipalIndex }
            catch {
                $state.Failed = $true
                Write-Error -Message ("Failed to read the Exchange Online service principals (Get-ServicePrincipal): {0}" -f $_.Exception.Message)
                return
            }
        }

        $application = $null
        if ($PSCmdlet.ParameterSetName -ne 'All') {
            $identity = switch ($PSCmdlet.ParameterSetName) {
                'ByName'       { @{ DisplayName = $RegisteredAppName } }
                'ByAppId'      { @{ AppId = $AppId } }
                'BySpObjectId' { @{ SpObjectId = $SpObjectId } }
            }
            try { $application = Resolve-RBAC4AppServicePrincipal @identity -Directory $state.Index.All }
            catch {
                Write-Error -Message $_.Exception.Message
                return
            }
            if (-not $application) {
                Write-Error -Message ("No Exchange Online service principal found matching '{0}'. It must already be registered via Register-EXOServicePrincipal, New-RBAC4AppEntry, or Invoke-RBAC4AppConfig." -f @($identity.Values)[0])
                return
            }
        }

        if ($null -eq $state.Assignments) {
            try { $state.Assignments = @(Get-RBAC4AppAssignmentSet @setFilter) }
            catch {
                $state.Failed = $true
                Write-Error -Message ("Failed to read the management role assignments (Get-ManagementRoleAssignment): {0}" -f $_.Exception.Message)
                return
            }
        }

        foreach ($assignment in $state.Assignments) {
            $assignee = Resolve-RBAC4AppAssignee -Assignment $assignment -Index $state.Index -AllAssignments $state.Assignments -Cache $state.AssigneeCache
            if ($application -and -not (Test-RBAC4AppAssigneeMatch -Assignee $assignee -Application $application)) { continue }

            $scope = Resolve-RBAC4AppScope -Assignment $assignment -Cache $state.ScopeCache
            $row = ConvertTo-RBAC4AppEntryRow -Assignment $assignment -Assignee $assignee -Scope $scope
            foreach ($warning in $row.Warnings) {
                if ($state.Warned.Add($warning)) { Write-Warning -Message $warning }
            }
            $row
        }
    }
}
