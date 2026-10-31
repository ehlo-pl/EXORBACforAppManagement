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
service principal pointer (Get-ServicePrincipal, matched by exact DisplayName; no Microsoft
Graph session is needed) to expose the application's AppId and ServicePrincipalId, and resolves
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
Invoke-RBAC4AppConfig. By default, files are written to the current directory.

.PARAMETER ExportPath
Optional output path. A directory writes one normalized file per role assignment; a file path
contains the config for one assignment or all exported configs when there are multiple assignments.

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
  ServicePrincipalId - Service principal object id, from Get-ServicePrincipal (null when
                       unresolved).
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
  ServicePrincipalId      - Service principal object id (null when unresolved).
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
  client-side by exact DisplayName against each distinct assignee.
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

        $exportCount = if ($ExportConfig) { @($assignments).Count } else { 0 }
        $combinedConfigs = [System.Collections.Generic.List[object]]::new()
        $exportPathIsFile = [bool](
            $ExportPath -and
            -not (Test-Path -LiteralPath $ExportPath -PathType Container) -and
            [string]$ExportPath -notmatch '[\\/]$' -and
            [System.IO.Path]::GetExtension($ExportPath)
        )

        $exportAssignment = {
            param(
                [psobject] $Assignment,
                [object] $ResolvedSp,
                [psobject] $Scope
            )

            if (-not $Assignment -or -not $ResolvedSp -or -not $ResolvedSp.AppId -or -not $ResolvedSp.ObjectId) {
                Write-Error -Message ("Cannot export role assignment '{0}' because its service principal AppId and object id could not be resolved." -f $Assignment.Name)
                return
            }

            if ([string]$Assignment.Role -notlike 'Application *') {
                Write-Error -Message ("Cannot export role assignment '{0}' because '{1}' is not an application role." -f $Assignment.Name, $Assignment.Role)
                return
            }

            $scopeKind = if ($Scope.ScopeKind -eq 'GroupDirect') { 'Group' } else { [string]$Scope.ScopeKind }
            if ($scopeKind -notin @('Group', 'Recipients', 'Tag', 'Filter')) {
                Write-Error -Message ("Cannot export role assignment '{0}' because its recipient scope could not be resolved to a supported config scope." -f $Assignment.Name)
                return
            }

            $resolvedGroupType = if ($Scope.ScopeGroupType -in @('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')) {
                [string]$Scope.ScopeGroupType
            }
            else { $null }

            if ($scopeKind -eq 'Group' -and (-not $Scope.ScopeGroupName -or -not $resolvedGroupType)) {
                Write-Error -Message ("Cannot export role assignment '{0}' because its scope group name or type could not be resolved." -f $Assignment.Name)
                return
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
                Write-Error -Message ("Cannot export role assignment '{0}' because its {1} scope data is incomplete." -f $Assignment.Name, $scopeKind)
                return
            }

            $accessGroupName = if ($scopeKind -eq 'Group') {
                if ($Scope.ScopeGroupName) { [string]$Scope.ScopeGroupName } else { [string]$Scope.ScopeName }
            }
            else { '' }
            $scopeRecipients = if ($scopeKind -eq 'Recipients') { @($Scope.Members) } else { @() }
            $config = ConvertTo-RBAC4AppConfig `
                -AppId ([string]$ResolvedSp.AppId) `
                -SpObjectId ([string]$ResolvedSp.ObjectId) `
                -DisplayName ([string]($ResolvedSp.DisplayName -replace '_SP$', '')) `
                -Roles ([string]$Assignment.Role) `
                -AccessGroupType $accessGroupType `
                -GroupPrefix (Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $accessGroupType) `
                -AccessGroupName $accessGroupName `
                -Members $(if ($scopeKind -eq 'Group') { @($Scope.Members) } else { @() }) `
                -ManagedBy @('GraphAPI-Dummy-owner') `
                -ScopeKind $scopeKind `
                -ManagementScopeName $(if ($Scope.ManagementScope) { [string]$Scope.ManagementScope } else { '' }) `
                -ManagementScopePrefix $script:RBAC4AppDefaultManagementScopePrefix `
                -ScopeRecipients $scopeRecipients `
                -ScopeTagAttribute $scopeTagAttribute `
                -ScopeTagValue $scopeTagValue `
                -ScopeFilter $scopeFilter

            $extension = if ($ExportFormat -eq 'Json') { '.json' } else { '.yml' }
            if ($exportPathIsFile -and $exportCount -gt 1) {
                $combinedConfigs.Add($config)
                return
            }

            $safeName = Format-RBAC4AppSafeName -Value ([string]$Assignment.Name) -MaxLength 120
            if (-not $safeName) {
                $safeName = Format-RBAC4AppSafeName -Value ("{0}-{1}" -f $ResolvedSp.DisplayName, $Assignment.Role) -MaxLength 120
            }
            $fileName = "rbac4app-$safeName$extension"
            $targetPath = $null

            if (-not $ExportPath) {
                $targetPath = Join-Path (Get-Location).Path $fileName
            }
            elseif ((Test-Path -LiteralPath $ExportPath -PathType Container) -or
                [string]$ExportPath -match '[\\/]$' -or
                -not [System.IO.Path]::GetExtension($ExportPath)) {
                $targetPath = Join-Path $ExportPath $fileName
            }
            elseif ($exportPathIsFile) {
                $targetPath = [System.IO.Path]::ChangeExtension($ExportPath, $extension)
            }

            if ($PSCmdlet.ShouldProcess($targetPath, "Write RBAC4App config ($ExportFormat)")) {
                $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($targetPath))
                if (-not [System.IO.Directory]::Exists($parent)) {
                    [void][System.IO.Directory]::CreateDirectory($parent)
                }
                $serialized = if ($ExportFormat -eq 'Json') { $config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $config }
                [System.IO.File]::WriteAllText($targetPath, $serialized, [System.Text.Encoding]::UTF8)
                Write-Verbose "Config written to '$targetPath'."
            }
        }

        $writeCombinedExport = {
            if ($combinedConfigs.Count -eq 0) { return }

            $extension = if ($ExportFormat -eq 'Json') { '.json' } else { '.yml' }
            $targetPath = [System.IO.Path]::ChangeExtension($ExportPath, $extension)
            if ($PSCmdlet.ShouldProcess($targetPath, "Write $($combinedConfigs.Count) RBAC4App configs ($ExportFormat)")) {
                $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($targetPath))
                if (-not [System.IO.Directory]::Exists($parent)) {
                    [void][System.IO.Directory]::CreateDirectory($parent)
                }
                # JSON is a YAML subset, so the same multi-config payload is valid in either format.
                $serialized = ConvertTo-Json -InputObject @($combinedConfigs) -Depth 6
                [System.IO.File]::WriteAllText($targetPath, $serialized, [System.Text.Encoding]::UTF8)
                Write-Verbose "Config written to '$targetPath'."
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
                    foreach ($assignment in $assignmentGroup.Group) {
                        $assignmentScope = Resolve-RBAC4AppScope -Assignment $assignment -Cache $scopeCache
                        & $exportAssignment $assignment $resolvedSp $assignmentScope
                    }
                }

                [pscustomobject][ordered]@{
                    DisplayName             = Get-DisplayNameFor $assigneeName $resolvedSp 'ServicePrincipal'
                    AppId                   = if ($resolvedSp) { [string]$resolvedSp.AppId } else { $null }
                    ServicePrincipalId      = if ($resolvedSp) { [string]$resolvedSp.ObjectId } else { $null }
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
            if ($ExportConfig) { & $writeCombinedExport }
            return
        }

        foreach ($a in $assignments) {
            $assigneeName = [string]$a.RoleAssigneeName
            $resolvedSp = $spByAssignee[$assigneeName]
            $scope = Resolve-RBAC4AppScope -Assignment $a -Cache $scopeCache

            if ($ExportConfig) {
                & $exportAssignment $a $resolvedSp $scope
            }

            [pscustomobject][ordered]@{
                Name               = $a.Name
                Role               = $a.Role
                RoleAssigneeName   = $a.RoleAssigneeName
                RoleAssigneeType   = $a.RoleAssigneeType
                EffectiveUserName  = $a.EffectiveUserName
                App                = $a.App
                DisplayName        = Get-DisplayNameFor $assigneeName $resolvedSp $a.RoleAssigneeType
                AppId              = if ($resolvedSp) { [string]$resolvedSp.AppId } else { $null }
                ServicePrincipalId = if ($resolvedSp) { [string]$resolvedSp.ObjectId } else { $null }
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
        if ($ExportConfig) { & $writeCombinedExport }
    }
}
