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
(formerly the separate Get-RegisteredAppWithPermission function, which has been removed).

With -ApplicationAccessPolicy, it returns the raw Application Access Policy objects from
Get-ApplicationAccessPolicy instead of RBAC role assignments. The existing application
identity filters are preserved; AppId is passed to the policy cmdlet, while display name
and service principal object id are resolved through the Exchange Online service principal.

In the RBAC assignment views, every row resolves the assignee back to its Exchange Online
service principal pointer (Get-ServicePrincipal, matched by object id first since this module's
own assignments are bound by -App <ObjectId>, falling back to exact DisplayName; no Microsoft
Graph session is needed). If a pointer's object id is missing, a unique generated role-assignment
name can also identify it when the assignment's GUID agrees with EffectiveUserName. This name-based
fallback warns because assignment names are not authoritative. The result exposes the application's
AppId and ServicePrincipalId, and resolves
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

.PARAMETER ApplicationAccessPolicy
Return raw Application Access Policy objects from Get-ApplicationAccessPolicy instead of
RBAC role assignments. With no identity filter, returns all policies. The existing
-RegisteredAppName, -AppId, and -SpObjectId filters limit the result to that application.
Requires an Exchange Online session where Get-ApplicationAccessPolicy is available.

.PARAMETER ExportConfig
Export each returned RBAC role assignment as a schema-compatible YAML or JSON config for
Invoke-RBAC4AppConfig. By default, files are written to the current directory. With
-ByApplication, one config is exported per application (rbac4app-<DisplayName>) holding all of
its roles; an application whose assignments use several distinct scopes gets one config per scope.
Export is best effort: when a scope group can no longer be read, the config is still written with
the group name, an AccessGroupType inferred from its prefix, and no members (with a warning). An
assignment is skipped (non-terminating error) only when no usable config can be built, e.g. its
service principal cannot be resolved; the remaining configs are still written. An empty service
principal object id is replaced by the GUID found in EffectiveUserName (see ServicePrincipalId below).
Warnings raised while building a config (that fallback, an inferred group type) are also written to
the config's Runtime.CollectedWarnings.

.PARAMETER ExportPath
Optional output path. A directory writes one normalized file per exported config; a file path
contains that config when only one is exported, or a JSON array of all exported configs otherwise.

.PARAMETER ExportFormat
Config format to write: Yaml (default) or Json.

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

.EXAMPLE
Get-RBAC4AppEntry -ApplicationAccessPolicy

Returns all Application Access Policies, without resolving RBAC role assignments.

.EXAMPLE
Get-RBAC4AppEntry -ApplicationAccessPolicy -AppId '11111111-2222-3333-4444-555555555555'

Returns Application Access Policies for the specified application.

.EXAMPLE
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -ExportConfig -ExportFormat Json

Exports each matching role assignment as a JSON config for Invoke-RBAC4AppConfig.

.OUTPUTS
PSCustomObject

With -ApplicationAccessPolicy, returns the raw objects emitted by Get-ApplicationAccessPolicy
(including AppId, AccessRight, ScopeName, and Description).

Per-assignment view (default), one object per matching assignment:

  Name               - Management role assignment name.
  RoleAssignmentName - Management role assignment name (same as Name).
  Role               - Full application role name (e.g. "Application Mail.Send").
  RoleAssigneeName   - Raw EXO assignee name (e.g. "Contoso_SP").
  RoleAssigneeType   - Assignee type (ServicePrincipal, RoleGroup, ...).
  EffectiveUserName  - Raw EffectiveUserName from Get-ManagementRoleAssignment. Exchange Online
                       leaves this blank/placeholder for application-role assignments; surfaced
                       as-is for completeness.
  App                - Raw App from Get-ManagementRoleAssignment. Exchange Online leaves this
                       blank/placeholder for application-role assignments; surfaced as-is for
                       completeness (not to be confused with the resolved AppId below).
  DisplayName        - Application display name, "_SP" suffix stripped (best-effort for
                       ServicePrincipal assignees even when the EXO pointer can't be resolved).
  AppId              - Application (client) id, from Get-ServicePrincipal (null when unresolved).
  ServicePrincipalId - Service principal object id, from Get-ServicePrincipal. When that comes
                       back empty (often an incomplete Connect-MgGraph / directory read), the
                       object id (GUID) found in EffectiveUserName is used instead, with a
                       warning; null when neither is available.
  Scope              - Resolved scope: the scope group name for a group-based scope (ScopeKind
                       Group or GroupDirect), otherwise the management scope name. Resolved via
                       the private Resolve-RBAC4AppScope helper, not the raw EXO scope fields. Null
                       when the assignment has no recipient scope.
  ManagementScope    - Name of the management scope the assignment is bound to
                       (-CustomResourceScope); null for legacy group-scoped assignments.
  ScopeKind          - Group, Recipients, Tag, or Filter (classified from the management scope's
                       RecipientFilter); GroupDirect for a legacy -RecipientGroupScope assignment.
  ScopeFilter        - The management scope's RecipientFilter (null for GroupDirect).
  ScopeGroupType     - M365Group, DistributionList, or MailEnabledSecurityGroup for a group-based
                       scope; null otherwise or when the group can't be resolved.
  ScopeMembers       - Sorted, unique recipients in scope (PrimarySmtpAddress, falling back to
                       Name): the group's members, the Recipients list, or - for Tag/Filter - a
                       Get-Recipient -RecipientPreviewFilter preview capped at 1000.
  RecipientScope     - Raw RecipientWriteScope value (Group, CustomRecipientScope, ...).
  Enabled            - Whether the assignment is enabled.
  Guid               - Assignment Guid.
  Identity           - Assignment Identity.

Per-application view (-ByApplication), one object per distinct application:

  DisplayName             - Application display name (or the "_SP"-stripped assignee when
                            unresolved).
  AppId                   - Application (client) id (null when unresolved).
  ServicePrincipalId      - Service principal object id; falls back (with a warning) to the GUID
                            found in the app's EffectiveUserNames when empty; null when unresolved.
  ExoServicePrincipal     - The raw Exchange Online assignee name (e.g. Contoso_SP).
  ManagementScopeNames    - Sorted, unique management scope name(s) the app's assignments are
                            bound to (empty for legacy group-scoped assignments).
  ScopeKinds              - Sorted, unique ScopeKind values across the app's assignments.
  ScopeGroupNames         - Sorted, unique resolved scope group name(s) across the app's
                            assignments. Empty when an assignment has no group scope or its scope
                            group could not be resolved.
  ScopeGroupMembers       - Sorted, unique in-scope recipients across every resolved scope
                            (group members, Recipients lists, Tag/Filter previews).
  Roles                   - Sorted, unique application roles the app holds.
  RoleAssignmentNames     - Sorted, unique management role assignment names.
  EffectiveUserNames      - Sorted, unique non-blank EffectiveUserName values across the app's
                            assignments (raw EXO field; typically empty for application roles).
  Apps                    - Sorted, unique non-blank App values across the app's assignments (raw
                            EXO field; typically empty for application roles).
  AssignmentCount         - Total matched assignments for the app.
  EnabledAssignmentCount  - Count of those that are enabled.
  DisabledAssignmentCount - Count of those that are disabled.

.NOTES
Requires a connected Exchange Online session only (Get-ManagementRoleAssignment,
Get-ServicePrincipal, Get-ManagementScope, Get-Recipient, Get-UnifiedGroup, Get-UnifiedGroupLinks,
Get-DistributionGroup, Get-DistributionGroupMember). The -ApplicationAccessPolicy mode additionally
requires Get-ApplicationAccessPolicy. No Microsoft Graph session is needed; the application filter
for RBAC assignments only matches applications already registered via Register-EXOServicePrincipal,
New-RBAC4AppEntry, or Invoke-RBAC4AppConfig. Companion to New-RBAC4AppEntry.

Performance / behavior notes:
- With no -Role, one unfiltered Get-ManagementRoleAssignment call is made and results are
  filtered client-side to "Application *" roles; with -Role, one query per requested role
  (EXO does the role filtering).
- The EXO service principal directory (Get-ServicePrincipal) is read once per call and matched
  client-side against each distinct assignee: by object id first (how this module's own
  assignments are bound, via -App <ObjectId>), then by exact DisplayName.
- Scope resolution (Resolve-RBAC4AppScope) first probes Get-ManagementScope for assignments bound
  to a named management scope (one call per distinct scope; a Group-kind scope adds one
  Get-Recipient to resolve the group DN, a Tag/Filter scope one capped
  Get-RecipientPreviewFilter preview). Group resolution then adds up to two read calls
  (Get-UnifiedGroup/Get-DistributionGroup, then Get-UnifiedGroupLinks/Get-DistributionGroupMember)
  per distinct Group-scoped scope name, cached for the duration of the call so a group shared by
  several assignments/applications is only read once.
#>
function Get-RBAC4AppEntry {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'All')]
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
        [switch] $ByApplication,

        [Parameter()]
        [switch] $ApplicationAccessPolicy,

        [Parameter()]
        [switch] $ExportConfig,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ExportPath,

        [Parameter()]
        [ValidateSet('Yaml', 'Json')]
        [string] $ExportFormat = 'Yaml'
    )

    process {
        if ($ExportConfig -and $ApplicationAccessPolicy) {
            throw '-ExportConfig cannot be combined with -ApplicationAccessPolicy.'
        }

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

        if ($ApplicationAccessPolicy) {
            if (-not (Get-Command -Name Get-ApplicationAccessPolicy -ErrorAction SilentlyContinue)) {
                Write-Error -Message 'Get-ApplicationAccessPolicy is unavailable. Connect to Exchange Online with a session that provides this cmdlet.'
                return
            }

            try {
                $policyParameters = @{ ErrorAction = 'Stop' }
                if ($PSBoundParameters.ContainsKey('AppId')) {
                    $policyParameters.AppId = $AppId
                }
                elseif ($sp) {
                    $policyParameters.AppId = [string]$sp.AppId
                }
                @(Get-ApplicationAccessPolicy @policyParameters)
            }
            catch {
                Write-Error -Message ("Failed to read Application Access Policies: {0}" -f $_.Exception.Message)
            }
            return
        }

        # --- Retrieve assignments, filtered by role where possible.
        $rolesNormalized = if ($PSBoundParameters.ContainsKey('Role')) { @($Role | ForEach-Object { ConvertTo-RBAC4AppRoleName -Role $_ } | Select-Object -Unique) } else { @() }

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
        # Microsoft Graph session needed. Every role assignment this module creates is bound via
        # New-ManagementRoleAssignment -App <ObjectId>, so Exchange Online reports RoleAssigneeName
        # back as that raw service principal object id (a GUID), not its DisplayName - matched
        # first, with the DisplayName rule (both-forms, "_SP" stripped) as a fallback for any
        # assignment created the name-based way.
        $allExoServicePrincipals = @(Get-ServicePrincipal -ErrorAction SilentlyContinue)
        $exoSpByObjectId = @{}
        foreach ($exoSp in $allExoServicePrincipals) {
            if ($exoSp -and $exoSp.ObjectId) { $exoSpByObjectId[[string]$exoSp.ObjectId] = $exoSp }
        }
        $spByAssignee = @{}
        $spResolutionWarnings = @{}
        $warnedAssignees = [System.Collections.Generic.HashSet[string]]::new()
        $roleMap = Get-AppRoleMap
        foreach ($a in $assignments) {
            $assigneeName = [string]$a.RoleAssigneeName
            if ($spByAssignee.ContainsKey($assigneeName)) { continue }

            $resolved = $exoSpByObjectId[$assigneeName]
            if (-not $resolved) {
                $resolved = $allExoServicePrincipals | Where-Object { $_ -and ([string]$_.DisplayName -eq $assigneeName) } | Select-Object -First 1
            }
            if (-not $resolved -and $assigneeName) {
                $normalizedAssigneeName = $assigneeName -replace '_SP$', ''
                $resolved = $allExoServicePrincipals |
                    Where-Object { $_ -and (([string]$_.DisplayName -replace '_SP$', '') -eq $normalizedAssigneeName) } |
                    Select-Object -First 1
            }
            if (-not $resolved -and $a.RoleAssigneeType -eq 'ServicePrincipal' -and
                $assigneeName -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                $matchingAssignments = @($assignments | Where-Object {
                    $_.RoleAssigneeType -eq 'ServicePrincipal' -and [string]$_.RoleAssigneeName -eq $assigneeName -and
                    (Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @($_.EffectiveUserName)) -eq $assigneeName
                })
                $conflictingAssignments = @($assignments | Where-Object {
                    if ($_.RoleAssigneeType -ne 'ServicePrincipal' -or [string]$_.RoleAssigneeName -ne $assigneeName) { return $false }
                    $effectiveId = Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @($_.EffectiveUserName)
                    $effectiveId -and $effectiveId -ne $assigneeName
                })
                $nameMatches = @($allExoServicePrincipals | Where-Object {
                    $candidate = $_
                    if (-not $candidate -or -not $candidate.AppId -or -not $candidate.DisplayName) { return $false }
                    $candidateName = [string]$candidate.DisplayName -replace '_SP$', ''
                    if (-not $candidateName) { return $false }
                    foreach ($assignment in $matchingAssignments) {
                        $shortRole = $roleMap[[string]$assignment.Role]
                        if ($shortRole -and [string]$assignment.Name -eq (Get-RBAC4AppRoleAssignmentName -ShortRoleName $shortRole -DisplayName $candidateName -AppId ([string]$candidate.AppId))) {
                            return $true
                        }
                    }
                    return $false
                })
                if ($nameMatches.Count -eq 1 -and -not $nameMatches[0].ObjectId -and $conflictingAssignments.Count -eq 0) {
                    $resolved = $nameMatches[0]
                    $spResolutionWarnings[$assigneeName] = "Resolved EXO assignee '{0}' from a generated role assignment name because the pointer's object id is missing; verify the application identity before using an exported config." -f $assigneeName
                    Write-Warning -Message $spResolutionWarnings[$assigneeName]
                }
            }
            $spByAssignee[$assigneeName] = $resolved

            if (-not $resolved -and $a.RoleAssigneeType -eq 'ServicePrincipal' -and $warnedAssignees.Add($assigneeName)) {
                Write-Warning -Message ("Could not resolve EXO assignee '{0}' to an Exchange Online service principal; AppId will be empty, and ServicePrincipalId too unless EffectiveUserName carries an object id." -f $assigneeName)
            }
        }

        # --- Scope resolution, cached per distinct scope group name for the duration of the call.
        $scopeCache = @{}

        # Writes each distinct warning once per call (the same fallback can be hit by a row and by
        # its exported config).
        $warnedMessages = [System.Collections.Generic.HashSet[string]]::new()
        $warnOnce = {
            param([string] $Message)
            if ($warnedMessages.Add($Message)) { Write-Warning -Message $Message }
        }

        # Service principal object id for a row/config. When the resolved pointer has none (an
        # empty ObjectId usually means an incomplete Connect-MgGraph / directory read, not always
        # visible as $null from Get-MgContext), fall back to the object id Exchange Online carries in
        # the assignment's EffectiveUserName - only when it holds a GUID - and say so in a warning.
        $getSpObjectId = {
            param([object] $ResolvedSp, [object[]] $EffectiveUserNames, [string] $Label, [string] $RoleAssigneeType)
            $id = if ($ResolvedSp) { [string]$ResolvedSp.ObjectId } else { '' }
            if ($id -or $RoleAssigneeType -ne 'ServicePrincipal') {
                return [pscustomobject]@{ Id = $(if ($id) { $id } else { $null }); Warning = $null }
            }
            $fallback = Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName $EffectiveUserNames
            if ($fallback) {
                return [pscustomobject]@{
                    Id      = $fallback
                    Warning = ("ServicePrincipalId/SpObjectId for '{0}' was returned empty (often a sign of an incomplete Connect-MgGraph or directory read); using '{1}' from EffectiveUserName instead." -f $Label, $fallback)
                }
            }
            $warning = if ($ResolvedSp) {
                "ServicePrincipalId/SpObjectId for '{0}' was returned empty and EffectiveUserName holds no object id (GUID); the field is left empty." -f $Label
            }
            else { $null }
            [pscustomobject]@{ Id = $null; Warning = $warning }
        }

        # Configs are built while the rows stream, then written once at the end, so whether an
        # explicit file -ExportPath receives one config or a combined array depends on how many
        # configs were actually built (one per application with -ByApplication), not on the raw
        # assignment count.
        $pendingExports = [System.Collections.Generic.List[object]]::new()
        $exportPathIsFile = [bool](
            $ExportPath -and
            -not (Test-Path -LiteralPath $ExportPath -PathType Container) -and
            [string]$ExportPath -notmatch '[\\/]$' -and
            [System.IO.Path]::GetExtension($ExportPath)
        )

        # Builds one config from one or more role assignments that share the same application and
        # the same resolved recipient scope (all their roles go into Rbac.Roles) and queues it.
        $addExport = {
            param(
                [object[]] $Assignments,
                [object] $ResolvedSp,
                [psobject] $Scope,
                [string] $BaseName
            )

            $Assignments = @($Assignments | Where-Object { $_ })
            $label = ($Assignments | ForEach-Object { [string]$_.Name }) -join "', '"
            # Collected into the config's Runtime.CollectedWarnings as well as written interactively.
            $configWarnings = [System.Collections.Generic.List[string]]::new()
            if ($Assignments.Count -gt 0) {
                $resolutionWarning = $spResolutionWarnings[[string]$Assignments[0].RoleAssigneeName]
                if ($resolutionWarning) { $configWarnings.Add($resolutionWarning) }
            }

            $spObjectIdInfo = & $getSpObjectId $ResolvedSp @($Assignments | ForEach-Object { $_.EffectiveUserName }) ([string]($ResolvedSp.DisplayName -replace '_SP$', '')) 'ServicePrincipal'
            if ($spObjectIdInfo.Warning) {
                & $warnOnce $spObjectIdInfo.Warning
                $configWarnings.Add($spObjectIdInfo.Warning)
            }
            $spObjectIdForExport = [string]$spObjectIdInfo.Id

            if ($Assignments.Count -eq 0 -or -not $ResolvedSp -or -not $ResolvedSp.AppId -or -not $spObjectIdForExport) {
                Write-Error -Message ("Cannot export role assignment '{0}' because its service principal AppId and object id could not be resolved." -f $label)
                return
            }

            $nonAppRole = $Assignments | Where-Object { [string]$_.Role -notlike 'Application *' } | Select-Object -First 1
            if ($nonAppRole) {
                Write-Error -Message ("Cannot export role assignment '{0}' because '{1}' is not an application role." -f $nonAppRole.Name, $nonAppRole.Role)
                return
            }

            $scopeKind = if ($Scope.ScopeKind -eq 'GroupDirect') { 'Group' } else { [string]$Scope.ScopeKind }
            if ($scopeKind -notin @('Group', 'Recipients', 'Tag', 'Filter')) {
                Write-Error -Message ("Cannot export role assignment '{0}' because its recipient scope could not be resolved to a supported config scope." -f $label)
                return
            }

            $resolvedGroupType = if ($Scope.ScopeGroupType -in @('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')) {
                [string]$Scope.ScopeGroupType
            }
            else { $null }

            $groupNameForExport = if ($Scope.ScopeGroupName) { [string]$Scope.ScopeGroupName } else { [string]$Scope.ScopeName }
            if ($scopeKind -eq 'Group' -and -not $groupNameForExport) {
                Write-Error -Message ("Cannot export role assignment '{0}' because its scope group name could not be resolved." -f $label)
                return
            }
            if ($scopeKind -eq 'Group' -and -not $resolvedGroupType) {
                # The group itself could not be read (deleted, renamed, or not visible to this
                # session). Export anyway - best effort - inferring the type from the module's
                # naming convention, so the rest of the assignment is not lost; the file needs review.
                $resolvedGroupType = switch -Regex ($groupNameForExport) {
                    '^(?i)Um365' { 'M365Group'; break }
                    '^(?i)USRA'  { 'MailEnabledSecurityGroup'; break }
                    default      { 'DistributionList' }
                }
                $inferredMsg = "Role assignment '{0}': scope group '{1}' could not be resolved; exported with inferred AccessGroupType '{2}' and no members - review the config before using it." -f $label, $groupNameForExport, $resolvedGroupType
                Write-Warning -Message $inferredMsg
                $configWarnings.Add($inferredMsg)
            }
            $accessGroupType = if ($resolvedGroupType) { $resolvedGroupType } else { 'DistributionList' }

            $scopeTagAttribute = 'CustomAttribute1'
            $scopeTagValue = ''
            $scopeFilter = ''
            if ($scopeKind -eq 'Tag' -and [string]$Scope.ScopeFilter -match "(?i)^\s*(CustomAttribute(?:[1-9]|1[0-5]))\s+-eq\s+'((?:''|[^'])*)'\s*$") {
                $scopeTagAttribute = $Matches[1]
                $scopeTagValue = $Matches[2].Replace("''", "'")
            }
            elseif ($scopeKind -eq 'Tag') {
                $scopeKind = 'Filter'
                $scopeFilter = [string]$Scope.ScopeFilter
            }
            elseif ($scopeKind -eq 'Filter') {
                $scopeFilter = [string]$Scope.ScopeFilter
            }

            if (($scopeKind -eq 'Recipients' -and @($Scope.Members).Count -eq 0) -or
                ($scopeKind -eq 'Filter' -and -not $scopeFilter)) {
                Write-Error -Message ("Cannot export role assignment '{0}' because its {1} scope data is incomplete." -f $label, $scopeKind)
                return
            }

            $accessGroupName = if ($scopeKind -eq 'Group') { $groupNameForExport } else { '' }
            $scopeRecipients = if ($scopeKind -eq 'Recipients') { @($Scope.Members) } else { @() }
            $roles = @($Assignments | ForEach-Object { [string]$_.Role } | Sort-Object -Unique)
            $config = ConvertTo-RBAC4AppConfig `
                -AppId ([string]$ResolvedSp.AppId) `
                -SpObjectId $spObjectIdForExport `
                -DisplayName ([string]($ResolvedSp.DisplayName -replace '_SP$', '')) `
                -Roles $roles `
                -AccessGroupType $accessGroupType `
                -GroupPrefix (Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $accessGroupType) `
                -AccessGroupName $accessGroupName `
                -Members $(if ($scopeKind -eq 'Group') { @($Scope.Members) } else { @() }) `
                -ManagedBy @('GraphAPI-Dummy-owner') `
                -ScopeKind $scopeKind `
                -AssignmentScope $(if ($Scope.ScopeKind -eq 'GroupDirect') { 'RecipientGroupScope' } else { 'ManagementScope' }) `
                -ManagementScopeName $(if ($Scope.ManagementScope) { [string]$Scope.ManagementScope } else { '' }) `
                -ManagementScopePrefix $script:RBAC4AppDefaultManagementScopePrefix `
                -ScopeRecipients $scopeRecipients `
                -ScopeTagAttribute $scopeTagAttribute `
                -ScopeTagValue $scopeTagValue `
                -ScopeFilter $scopeFilter `
                -CollectedWarnings @($configWarnings)

            $safeName = Format-RBAC4AppSafeName -Value $BaseName -MaxLength 120
            if (-not $safeName) {
                $safeName = Format-RBAC4AppSafeName -Value ("{0}-{1}" -f $ResolvedSp.DisplayName, ($roles -join '-')) -MaxLength 120
            }
            $pendingExports.Add([pscustomobject]@{ Config = $config; SafeName = $safeName })
        }

        $writeExports = {
            if ($pendingExports.Count -eq 0) { return }

            $extension = if ($ExportFormat -eq 'Json') { '.json' } else { '.yml' }
            $writeFile = {
                param([string] $TargetPath, [string] $Serialized, [int] $Count)
                $what = if ($Count -gt 1) { "Write $Count RBAC4App configs ($ExportFormat)" } else { "Write RBAC4App config ($ExportFormat)" }
                if ($PSCmdlet.ShouldProcess($TargetPath, $what)) {
                    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($TargetPath))
                    if (-not [System.IO.Directory]::Exists($parent)) {
                        [void][System.IO.Directory]::CreateDirectory($parent)
                    }
                    [System.IO.File]::WriteAllText($TargetPath, $Serialized, [System.Text.Encoding]::UTF8)
                    Write-Verbose "Config written to '$TargetPath'."
                }
            }

            if ($exportPathIsFile) {
                $targetPath = [System.IO.Path]::ChangeExtension($ExportPath, $extension)
                if ($pendingExports.Count -gt 1) {
                    # JSON is a YAML subset, so the same multi-config payload is valid in either format.
                    $serialized = ConvertTo-Json -InputObject @($pendingExports | ForEach-Object { $_.Config }) -Depth 6
                }
                else {
                    $config = $pendingExports[0].Config
                    $serialized = if ($ExportFormat -eq 'Json') { $config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $config }
                }
                & $writeFile $targetPath $serialized $pendingExports.Count
                return
            }

            $directory = if ($ExportPath) { $ExportPath } else { (Get-Location).Path }
            $usedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($export in $pendingExports) {
                # Distinct names can sanitize to the same file name (two applications sharing a
                # display name, or assignment names differing only in stripped characters) - number
                # the duplicates instead of silently overwriting an earlier file from this run.
                $name = $export.SafeName
                $suffix = 1
                while (-not $usedNames.Add($name)) {
                    $suffix++
                    $name = "{0}-{1}" -f $export.SafeName, $suffix
                }
                $config = $export.Config
                $serialized = if ($ExportFormat -eq 'Json') { $config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $config }
                & $writeFile (Join-Path $directory "rbac4app-$name$extension") $serialized 1
            }
        }

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
                $effectiveUserNames = @($assignmentGroup.Group.EffectiveUserName | Where-Object { $_ } | Sort-Object -Unique)
                $apps = @($assignmentGroup.Group.App | Where-Object { $_ } | Sort-Object -Unique)

                $scopes = @($assignmentGroup.Group | ForEach-Object { Resolve-RBAC4AppScope -Assignment $_ -Cache $scopeCache })
                $scopeNames = @($scopes | Where-Object { $_.ScopeGroupName } | ForEach-Object { $_.ScopeGroupName } | Sort-Object -Unique)
                $managementScopeNames = @($scopes | Where-Object { $_.ManagementScope } | ForEach-Object { $_.ManagementScope } | Sort-Object -Unique)
                $scopeKinds = @($scopes | Where-Object { $_.ScopeKind } | ForEach-Object { $_.ScopeKind } | Sort-Object -Unique)
                $scopeMembers = @($scopes | ForEach-Object { $_.Members } | Where-Object { $_ } | Sort-Object -Unique)

                if ($ExportConfig) {
                    # One config per application: all of its roles sharing the same resolved scope
                    # go into a single config. A config holds exactly one scope, so an application
                    # whose assignments use several distinct scopes gets one config per scope.
                    $appDisplayName = Get-DisplayNameFor $assigneeName $resolvedSp 'ServicePrincipal'
                    $byScope = [ordered]@{}
                    foreach ($assignment in $assignmentGroup.Group) {
                        $assignmentScope = Resolve-RBAC4AppScope -Assignment $assignment -Cache $scopeCache
                        $scopeKey = '{0}|{1}|{2}' -f $assignmentScope.ScopeKind, $assignmentScope.ManagementScope, $assignmentScope.ScopeName
                        if (-not $byScope.Contains($scopeKey)) {
                            $byScope[$scopeKey] = [pscustomobject]@{ Scope = $assignmentScope; Assignments = [System.Collections.Generic.List[object]]::new() }
                        }
                        $byScope[$scopeKey].Assignments.Add($assignment)
                    }
                    foreach ($entry in $byScope.Values) {
                        $baseName = if ($byScope.Count -gt 1 -and $entry.Scope.ScopeName) { '{0}-{1}' -f $appDisplayName, $entry.Scope.ScopeName } else { $appDisplayName }
                        & $addExport @($entry.Assignments) $resolvedSp $entry.Scope $baseName
                    }
                }

                $appSpIdInfo = & $getSpObjectId $resolvedSp $effectiveUserNames (Get-DisplayNameFor $assigneeName $resolvedSp 'ServicePrincipal') ([string]@($assignmentGroup.Group)[0].RoleAssigneeType)
                if ($appSpIdInfo.Warning) { & $warnOnce $appSpIdInfo.Warning }

                [pscustomobject][ordered]@{
                    DisplayName             = Get-DisplayNameFor $assigneeName $resolvedSp 'ServicePrincipal'
                    AppId                   = if ($resolvedSp) { [string]$resolvedSp.AppId } else { $null }
                    ServicePrincipalId      = $appSpIdInfo.Id
                    ExoServicePrincipal     = $assigneeName
                    ManagementScopeNames    = $managementScopeNames
                    ScopeKinds              = $scopeKinds
                    ScopeGroupNames         = $scopeNames
                    ScopeGroupMembers       = $scopeMembers
                    Roles                   = $rolesForApp
                    RoleAssignmentNames     = $assignmentNames
                    EffectiveUserNames      = $effectiveUserNames
                    Apps                    = $apps
                    AssignmentCount         = $assignmentGroup.Count
                    EnabledAssignmentCount  = @($assignmentGroup.Group | Where-Object { $_.Enabled }).Count
                    DisabledAssignmentCount = @($assignmentGroup.Group | Where-Object { -not $_.Enabled }).Count
                }
            }
            if ($ExportConfig) { & $writeExports }
            return
        }

        foreach ($a in $assignments) {
            $assigneeName = [string]$a.RoleAssigneeName
            $resolvedSp = $spByAssignee[$assigneeName]
            $scope = Resolve-RBAC4AppScope -Assignment $a -Cache $scopeCache

            if ($ExportConfig) {
                & $addExport @($a) $resolvedSp $scope ([string]$a.Name)
            }

            $rowSpIdInfo = & $getSpObjectId $resolvedSp @($a.EffectiveUserName) (Get-DisplayNameFor $assigneeName $resolvedSp $a.RoleAssigneeType) ([string]$a.RoleAssigneeType)
            if ($rowSpIdInfo.Warning) { & $warnOnce $rowSpIdInfo.Warning }

            [pscustomobject][ordered]@{
                Name               = $a.Name
                RoleAssignmentName = $a.Name
                Role               = $a.Role
                RoleAssigneeName   = $a.RoleAssigneeName
                RoleAssigneeType   = $a.RoleAssigneeType
                EffectiveUserName  = $a.EffectiveUserName
                App                = $a.App
                DisplayName        = Get-DisplayNameFor $assigneeName $resolvedSp $a.RoleAssigneeType
                AppId              = if ($resolvedSp) { [string]$resolvedSp.AppId } else { $null }
                ServicePrincipalId = $rowSpIdInfo.Id
                Scope              = $scope.ScopeName
                ManagementScope    = $scope.ManagementScope
                ScopeKind          = $scope.ScopeKind
                ScopeFilter        = $scope.ScopeFilter
                ScopeGroupType     = $scope.ScopeGroupType
                ScopeMembers       = $scope.Members
                RecipientScope     = $a.RecipientWriteScope
                Enabled            = $a.Enabled
                Guid               = $a.Guid
                Identity           = $a.Identity
            }
        }
        if ($ExportConfig) { & $writeExports }
    }
}
