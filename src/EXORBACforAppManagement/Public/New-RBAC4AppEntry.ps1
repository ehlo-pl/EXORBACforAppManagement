<#
.SYNOPSIS
Creates or updates Exchange Online RBAC scoping for an Entra application service principal.

.DESCRIPTION
New-RBAC4AppEntry resolves an application against the Exchange Online service principal pointer
already registered for it (by display name, AppId, or service principal object id), creates the
scope group when needed, adds requested members, ensures the Exchange Online service principal
exists, ensures the Exchange Online management scope, and creates Exchange Online RBAC role
assignments for the application against that management scope.

Resolution is Exchange-Online-only: it looks up the pointer Register-EXOServicePrincipal creates
(via Get-ServicePrincipal), not the Entra service principal itself, so no Microsoft Graph session
is required. For an application that has never been registered in Exchange Online, none of
-RegisteredAppName, -AppId, or -SpObjectId alone is enough to create that pointer (AppId and the
service principal object id cannot be derived from each other without Graph): supply all three
together (-AppId, -SpObjectId, and -RegisteredAppName as the display name) to bootstrap it in one
call, or provision it in two Graph/EXO-separated steps with New-RBAC4AppConfig +
Invoke-RBAC4AppConfig instead.

Scope group creation/configuration is delegated to New-RBAC4AppScopeGroup, management scope
creation to New-RBAC4AppManagementScope, and the Exchange Online service principal step to
Register-EXOServicePrincipal. Every creation step is
idempotent: the scope group, the EXO service principal, and each role assignment are only created
if a matching one does not already exist, so re-running against an already-provisioned application
is safe - a role assignment that already exists and is scoped to the target management scope is left
alone (a warning notes it was skipped); requested members are still added to the scope group
regardless.

The function supports -WhatIf and -Confirm through SupportsShouldProcess.

Role assignments are bound to a named Exchange Online management scope
(New-ManagementRoleAssignment -CustomResourceScope), not directly to the group. The scope's
recipient filter is selected by -ScopeKind:
  - Group (default): MemberOfGroup -eq '<scope group DN>' - the group workflow above is unchanged;
    the group just feeds the scope. Note MemberOfGroup matches direct members only.
  - Recipients: specific mailboxes/UPNs from -ScopeRecipients (each resolved via Get-Recipient to
    its PrimarySmtpAddress). No group is created.
  - Tag: CustomAttributeN -eq '<value>' (-ScopeTagAttribute / -ScopeTagValue). No group is created
    and the attribute is NOT stamped by this function - stamp it on the target mailboxes yourself.
  - Filter: a raw OPATH -ScopeFilter. No group is created.
The scope is created when missing; an existing scope with a different filter is left unchanged
(warning) - use Set-RBAC4AppEntry to reconcile it. An existing role assignment still scoped
directly to the group (the pre-0.7 -RecipientGroupScope model) is left as-is with a warning;
Set-RBAC4AppEntry migrates it. Exchange Online caches permissions for 30 minutes to 2 hours.

.PARAMETER ScopeKind
How the management scope selects recipients: Group (default), Recipients, Tag, or Filter. Group
parameters (-AccessGroupType, -AccessGroupName, -GroupPrefix, -Members, -ManagedBy,
-BootstrapMember) apply to Group only and are ignored (with a warning) otherwise.

.PARAMETER ManagementScopeName
Explicit management scope name (max 64 characters). Cannot be combined with
-ManagementScopePrefix.

.PARAMETER ManagementScopePrefix
Prefix of the generated management scope name "{prefix}-{app display name}". Default 'MSRAo1P'.

.PARAMETER ScopeRecipients
Mailboxes/UPNs/SMTP addresses the application may access (-ScopeKind Recipients). For large or
frequently changing sets prefer -ScopeKind Tag.

.PARAMETER ScopeTagAttribute
CustomAttribute1..CustomAttribute15 used by -ScopeKind Tag. Default CustomAttribute1.

.PARAMETER ScopeTagValue
Value matched by -ScopeKind Tag. Defaults to the management scope name.

.PARAMETER ScopeFilter
Raw OPATH recipient restriction filter used by -ScopeKind Filter.

.PARAMETER RegisteredAppName
Display name of the registered application. Used to resolve an already-registered Exchange Online
service principal pointer by name, and as the display name when bootstrapping a never-before-seen
application together with -AppId and -SpObjectId.

.PARAMETER AppId
Application (client) id of the registered application.

.PARAMETER SpObjectId
Object id of the target service principal.

.PARAMETER Members
Recipients to add to the scope group. Values must resolve through
Get-Recipient. The default placeholder value is GraphAPI-Dummy.

.PARAMETER Role
Exchange Online application roles to assign. Short names such as Mail.Send are
normalized to Application Mail.Send where supported.

.PARAMETER ManagedBy
One or more recipients that will be assigned as the scope group's owners.

.PARAMETER GroupPrefix
Prefix used when building the scope group name. When omitted, defaults to 'UDLRAo1P'
(DistributionList), 'USRAo1P' (MailEnabledSecurityGroup), or 'Um365RAo1P' (M365Group) based on
-AccessGroupType.

.PARAMETER AccessGroupName
Explicit scope group name to use for RBAC scoping instead of generating a name from
GroupPrefix and the resolved service principal display name. Cannot be combined with
an explicit GroupPrefix value. Required when -AccessGroupType is MailEnabledSecurityGroup
(on-prem/hybrid-synced groups already have their own name and are never generated).

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope. One of:
  - DistributionList (default): create/configure an Exchange-Online-only distribution list.
  - M365Group: create/configure a Microsoft 365 Unified Group.
  - MailEnabledSecurityGroup: reference an existing on-prem/hybrid-synced mail-enabled
    security group. The group is never created or modified (it is mastered on-premises),
    -AccessGroupName is required, and -Members, -ManagedBy, and -BootstrapMember are all
    ignored (membership and ownership are managed on-premises).

.PARAMETER BootstrapMember
Optional initial member passed during scope group creation.

.PARAMETER ChangeReference
Optional change or incident reference to persist in a local metadata file under
~\.EXORBACforAppManagement\<change>.yaml without changing Exchange Online object names.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Verbose -WhatIf

Shows the planned service principal resolution, scope group and management scope creation, and RBAC
assignment actions without making changes.

.EXAMPLE
New-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' -Members 'sharedmailbox@contoso.com' -Role 'Mail.Send' -Verbose

Resolves the application by AppId, ensures the scoped group and management scope exist, adds the
recipient, and creates the Application Mail.Send role assignment bound to that management scope.

.EXAMPLE
New-RBAC4AppEntry -SpObjectId '11111111-2222-3333-4444-555555555555' -Role 'Application Calendars.Read','Application Contacts.Read' -GroupPrefix 'Um365Prod'

Uses the service principal object id directly and creates multiple application role
assignments scoped to the generated management scope.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupName 'RBAC-AppScope-ContosoMail' -Role 'Mail.Send'

Uses an explicit scope group name to build the management scope and assigns the requested RBAC role
to the application against that management scope.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType DistributionList -Members 'shared@contoso.com' -Role 'Mail.Send'

Creates an Exchange-Online-only distribution list as the scope group, adds the member, and
assigns the role scoped to that list.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-MailApp-Scope' -Role 'Mail.Send'

Builds the management scope from an existing on-prem/hybrid-synced mail-enabled security group.
The group is not created and its membership (managed on-premises) is left untouched.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AppId '11111111-2222-3333-4444-555555555555' -SpObjectId '66666666-7777-8888-9999-000000000000' -Role 'Mail.Send'

Bootstraps the Exchange Online service principal pointer for an application that has never been
registered before, from explicit identifiers, then proceeds as a normal creation.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -ScopeKind Recipients -ScopeRecipients 'alice@contoso.com','bob@contoso.com' -Role 'Mail.Send'

Scopes the role assignment to two specific mailboxes through the management scope
'MSRAo1P-ContosoMailApp'; no group is created.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -ScopeKind Tag -ScopeTagAttribute CustomAttribute5 -ScopeTagValue 'ContosoMailApp' -Role 'Mail.Read'

Scopes the role assignment to every recipient whose CustomAttribute5 is 'ContosoMailApp'.

.OUTPUTS
PSCustomObject

Returns a summary object with resolved identity, scope group and management scope names, normalized
roles, assignment names, warnings, and errors.

.NOTES
Requires a connected Exchange Online session only (Get-ServicePrincipal, Get-ConnectionInformation,
New-ServicePrincipal, Get-UnifiedGroup, Set-UnifiedGroup, Add-UnifiedGroupLinks,
Get-UnifiedGroupLinks, Get-DistributionGroupMember, Get-Recipient, Get-ManagementScope,
New-ManagementScope, Get-ManagementRoleAssignment, and New-ManagementRoleAssignment). No Microsoft
Graph session is needed.
#>
function New-RBAC4AppEntry {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        # Resolve by displayName of an already-registered EXO service principal pointer, or the
        # display name to use when bootstrapping a never-before-seen one (with -AppId/-SpObjectId).
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('DisplayName','Name')]
        [ValidateNotNullOrEmpty()]
        [string] $RegisteredAppName,

        # Resolve by AppId (GUID) of an already-registered EXO service principal pointer, or part
        # of the bootstrap triple (with -SpObjectId/-RegisteredAppName) for a never-before-seen one.
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('ClientId','ApplicationId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        # Resolve by Service Principal ObjectId (GUID) of an already-registered EXO service
        # principal pointer, or part of the bootstrap triple (with -AppId/-RegisteredAppName).
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Id','ObjectId','ServicePrincipalId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $SpObjectId,

        [Parameter(Position = 1)]
        [string[]] $Members = @("GraphAPI-Dummy"),

        [Parameter(Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role = @("Application Mail.Send"),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $ManagedBy = @("GraphAPI-Dummy-owner"),

        [Parameter()]
        [string] $GroupPrefix = $null,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'DistributionList',

        # Optional placeholder member (dont validate as email)
        [Parameter()]
        [string] $BootstrapMember = "GraphAPI-Dummy",

        [Parameter()]
        [ValidateSet('Group', 'Recipients', 'Tag', 'Filter')]
        [string] $ScopeKind = 'Group',

        [Parameter()]
        [ValidateLength(1, 64)]
        [string] $ManagementScopeName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagementScopePrefix = 'MSRAo1P',

        [Parameter()]
        [string[]] $ScopeRecipients,

        [Parameter()]
        [ValidatePattern('^CustomAttribute([1-9]|1[0-5])$')]
        [string] $ScopeTagAttribute = 'CustomAttribute1',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ScopeTagValue,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ScopeFilter,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference
    )

    begin {
        $shortRoleMap = Get-AppRoleMap

        $tenantid = $null
        try { $tenantid = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1 -ExpandProperty TenantId }
        catch { Write-Verbose -Message "Could not read tenant id from Get-ConnectionInformation: $($_.Exception.Message)" }
    }

    process {
        if ($PSBoundParameters.ContainsKey('AccessGroupName') -and $PSBoundParameters.ContainsKey('GroupPrefix')) {
            throw "Parameters -AccessGroupName and -GroupPrefix cannot be used together."
        }
        if ($PSBoundParameters.ContainsKey('ManagementScopeName') -and $PSBoundParameters.ContainsKey('ManagementScopePrefix')) {
            throw "Parameters -ManagementScopeName and -ManagementScopePrefix cannot be used together."
        }
        if ($ScopeKind -eq 'Recipients' -and -not $ScopeRecipients) {
            throw "-ScopeRecipients is required when -ScopeKind is Recipients."
        }
        if ($ScopeKind -eq 'Filter' -and -not $ScopeFilter) {
            throw "-ScopeFilter is required when -ScopeKind is Filter."
        }

        if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) {
            $GroupPrefix = switch ($AccessGroupType) {
                'DistributionList'         { 'UDLRAo1P' }
                'MailEnabledSecurityGroup' { 'USRAo1P' }
                default                    { 'Um365RAo1P' }
            }
        }

        if (-not $PSBoundParameters.ContainsKey('RegisteredAppName') -and
            -not $PSBoundParameters.ContainsKey('AppId') -and
            -not $PSBoundParameters.ContainsKey('SpObjectId')) {
            throw "One of -RegisteredAppName, -AppId, or -SpObjectId must be supplied."
        }

        $result = [ordered]@{
            ParameterSet      = $null
            IdentityInput     = $null
            ResolvedDisplay   = $null
            AppId             = $null
            SpObjectId        = $null
            TenantId          = $tenantid
            ScopeKind         = $ScopeKind
            ManagementScopeName   = $null
            ManagementScopeFilter = $null
            ManagementScopeCreated = $false
            AccessGroupType   = if ($ScopeKind -eq 'Group') { $AccessGroupType } else { $null }
            ScopeGroupName    = $null
            OwnerRequested    = if ($ScopeKind -eq 'Group') { @($ManagedBy) } else { @() }
            OwnerAdded        = $null
            MembersRequested  = if ($ScopeKind -eq 'Group') { @($Members) } else { @() }
            MembersAdded      = @()
            MembersFinal      = @()
            FilteredMembers   = @()
            ChangeReference   = if ($PSBoundParameters.ContainsKey('ChangeReference')) { $ChangeReference } else { $null }
            ChangeReferencePath = $null
            RolesNormalized   = @()
            RoleAssignments   = @()
            RoleAssignmentsName = @()
            Warnings          = @()
            Errors            = @()
        }

        try {
            # --- Resolve the service principal against the Exchange Online service principal
            # pointer already registered via Register-EXOServicePrincipal, New-RBAC4AppEntry, or
            # Invoke-RBAC4AppConfig. Preference order when more than one identifier is supplied:
            # SpObjectId, then AppId, then RegisteredAppName.
            $sp = $null
            if ($PSBoundParameters.ContainsKey('SpObjectId')) {
                $result.ParameterSet  = 'BySpObjectId'
                $result.IdentityInput = $SpObjectId
                $sp = Resolve-RBAC4AppServicePrincipal -SpObjectId $SpObjectId
            }
            elseif ($PSBoundParameters.ContainsKey('AppId')) {
                $result.ParameterSet  = 'ByAppId'
                $result.IdentityInput = $AppId
                $sp = Resolve-RBAC4AppServicePrincipal -AppId $AppId
            }
            else {
                $result.ParameterSet  = 'ByName'
                $result.IdentityInput = $RegisteredAppName
                $sp = Resolve-RBAC4AppServicePrincipal -DisplayName $RegisteredAppName
            }

            if (-not $sp) {
                # --- Never registered in Exchange Online yet: bootstrap it, but only if the caller
                # supplied everything New-ServicePrincipal needs (AppId + SpObjectId + a display
                # name). Neither can be derived from the other without Microsoft Graph.
                if ($AppId -and $SpObjectId -and $RegisteredAppName) {
                    Write-Verbose -Message "No existing Exchange Online service principal matched; registering a new one from the supplied -AppId/-SpObjectId/-RegisteredAppName."
                    $sp = [pscustomobject]@{ AppId = $AppId; Id = $SpObjectId; DisplayName = $RegisteredAppName }
                }
                else {
                    throw "No Exchange Online service principal found matching the supplied identity, and there is not enough information to register one. Supply -AppId, -SpObjectId, and -RegisteredAppName together to register a never-before-seen application, or provision it first with New-RBAC4AppConfig + Invoke-RBAC4AppConfig."
                }
            }

            $result.ResolvedDisplay = $sp.DisplayName
            $result.AppId           = $sp.AppId
            $result.SpObjectId      = $sp.Id

            foreach ($ignoredMsg in @(Get-RBAC4AppScopeKindWarning -ScopeKind $ScopeKind -BoundParameters $PSBoundParameters)) {
                $result.Warnings += $ignoredMsg
                Write-Warning -Message $ignoredMsg
            }

            $ugResult = $null
            $umGroupName = $null
            if ($ScopeKind -eq 'Group') {
                # --- Resolve the scope group name. A MailEnabledSecurityGroup is on-prem/hybrid-synced:
                # it already has its own name and is never generated, so -AccessGroupName is required.
                if ($PSBoundParameters.ContainsKey('AccessGroupName')) {
                    $umGroupName = if ($AccessGroupType -eq 'MailEnabledSecurityGroup') { $AccessGroupName } else { Get-SafeName -s $AccessGroupName }
                }
                elseif ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                    throw "-AccessGroupName is required when -AccessGroupType is MailEnabledSecurityGroup; on-prem/hybrid-synced groups are referenced by their existing name, not generated."
                }
                else {
                    $umGroupName = "{0}-{1}" -f $GroupPrefix, $sp.DisplayName
                    $umGroupName = Get-SafeName($umGroupName)
                }
                $result.ScopeGroupName = $umGroupName

                # --- Ensure the scope group (delegated to New-RBAC4AppScopeGroup, which dispatches on type).
                Write-Verbose -Message ("Checking {0} '{1}' for service principal '{2}' ({3})." -f $AccessGroupType, $umGroupName, $sp.DisplayName, $sp.Id)
                $scopeGroupParams = @{
                    AccessGroupType = $AccessGroupType
                    Name            = $umGroupName
                    ManagedBy       = $ManagedBy
                    BootstrapMember = $BootstrapMember
                    WarningVariable = 'ugWarnings'
                }
                if ($PSBoundParameters.ContainsKey('ChangeReference')) { $scopeGroupParams['ChangeReference'] = $ChangeReference }
                $ugResult = New-RBAC4AppScopeGroup @scopeGroupParams
                foreach ($w in $ugWarnings) {
                    if ([string]$w.Message -like '*already exists*') { $result.Warnings += [string]$w.Message }
                }
                if ($ugResult) {
                    $result.OwnerRequested = $ugResult.OwnerRequested
                    $result.OwnerAdded    = $ugResult.OwnerAdded
                    $result.ChangeReferencePath = $ugResult.ChangeReferencePath
                }

                # --- Read the group's current membership once (all types, read-only): seeds MembersFinal
                # below and is reused rather than re-queried after any additions (EXO reads can lag
                # writes, so a fresh post-write read would not reliably reflect what was just added).
                $existingLinks = if ($AccessGroupType -eq 'M365Group') {
                    @(Get-UnifiedGroupLinks -Identity $umGroupName -LinkType Members -ErrorAction SilentlyContinue)
                }
                else {
                    @(Get-DistributionGroupMember -Identity $umGroupName -ErrorAction SilentlyContinue)
                }
                $existingMemberIdentities = @($existingLinks | ForEach-Object {
                        if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
                    } | Where-Object { $_ } | Select-Object -Unique)

                # --- MailEnabledSecurityGroup is on-prem/hybrid-synced: it is never created or modified
                # here, so warn about any group-modifying parameter that was requested but ignored.
                if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                    if ($PSBoundParameters.ContainsKey('Members')) {
                        $skipMembersMsg = "Membership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; -Members was ignored."
                        $result.Warnings += $skipMembersMsg
                        Write-Warning -Message $skipMembersMsg
                    }
                    if ($ManagedBy -and (@($ManagedBy) -join ',') -ne 'GraphAPI-Dummy-owner') {
                        $skipOwnerMsg = "Ownership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; -ManagedBy was ignored."
                        $result.Warnings += $skipOwnerMsg
                        Write-Warning -Message $skipOwnerMsg
                    }
                    if ($BootstrapMember -and $BootstrapMember -ne 'GraphAPI-Dummy') {
                        $skipBootstrapMsg = "Initial membership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; -BootstrapMember was ignored."
                        $result.Warnings += $skipBootstrapMsg
                        Write-Warning -Message $skipBootstrapMsg
                    }
                }
                else {
                    $currentUserUpn = $null
                    try {
                        $connectionInfo = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1
                        $currentUserUpn = $connectionInfo.UserPrincipalName
                    }
                    catch {
                        $result.Warnings += "Could not retrieve current connection user via Get-ConnectionInformation; connection user filtering will be skipped. Error: $($_.Exception.Message)"
                        Write-Warning -Message "Could not retrieve current connection user via Get-ConnectionInformation; connection user filtering will be skipped."
                    }

                    foreach ($member in $Members) {
                        if (-not $member) { continue }

                        $rec = Get-Recipient -Identity $member -ErrorAction SilentlyContinue
                        if (-not $rec) {
                            $result.Warnings += "Recipient not found for '$member' (skipped)."
                            continue
                        }
                        if ($currentUserUpn -and ($member -ieq $currentUserUpn)) {
                            $result.FilteredMembers += [string]$rec.PrimarySmtpAddress
                            $filterWarning = "Current connection user '$currentUserUpn' was found in the members list and has been filtered out."
                            $result.Warnings += $filterWarning
                            Write-Warning -Message $filterWarning
                            continue
                        }

                        if ($PSCmdlet.ShouldProcess("$AccessGroupType $umGroupName", "Add member $($rec.PrimarySmtpAddress)")) {
                            if ($AccessGroupType -eq 'DistributionList') {
                                Add-DistributionGroupMember -Identity $umGroupName -Member $rec.PrimarySmtpAddress -ErrorAction Stop
                            }
                            else {
                                Add-UnifiedGroupLinks -Identity $umGroupName -LinkType Members -Links $rec.PrimarySmtpAddress -ErrorAction Stop
                            }
                        }
                        $result.MembersAdded += [string]$rec.PrimarySmtpAddress
                    }
                }

                $result.MembersFinal = @($existingMemberIdentities + $result.MembersAdded | Select-Object -Unique)
            }

            # --- Ensure EXO ServicePrincipal extension (delegated to Register-EXOServicePrincipal)
            $exoSpDisplay = "{0}_SP" -f $sp.DisplayName
            $null = Register-EXOServicePrincipal -AppId $sp.AppId -ObjectId $sp.Id -DisplayName $exoSpDisplay

            # --- Ensure the management scope the role assignments are bound to. An existing scope
            # whose filter differs is left unchanged (warned); Set-RBAC4AppEntry reconciles it.
            $scopeName = Get-RBAC4AppManagementScopeName -DisplayName $sp.DisplayName -Prefix $ManagementScopePrefix -Name $ManagementScopeName
            $result.ManagementScopeName = $scopeName
            $groupDn = if ($ugResult -and $ugResult.Group) { [string]$ugResult.Group.DistinguishedName } else { $null }
            $filterArgs = @{
                ScopeKind              = $ScopeKind
                GroupIdentity          = $umGroupName
                GroupDistinguishedName = $groupDn
                Recipients             = $ScopeRecipients
                TagAttribute           = $ScopeTagAttribute
                TagValue               = if ($ScopeTagValue) { $ScopeTagValue } else { $scopeName }
                Filter                 = $ScopeFilter
                AllowUnresolved        = ($ScopeKind -eq 'Group' -and [bool]$WhatIfPreference)
            }
            $scopeFilterText = ConvertTo-RBAC4AppRecipientFilter @filterArgs
            $scopeResult = New-RBAC4AppManagementScope -Name $scopeName -RecipientRestrictionFilter $scopeFilterText -NoUpdate -WarningVariable msWarnings
            foreach ($w in $msWarnings) { $result.Warnings += [string]$w.Message }
            $result.ManagementScopeFilter  = $scopeResult.RecipientRestrictionFilter
            $result.ManagementScopeCreated = [bool]$scopeResult.Created
            if ($ScopeKind -eq 'Tag') {
                Write-Verbose -Message ("Management scope '{0}' targets recipients with {1}; stamp that attribute on the mailboxes the app may access (not done by this module)." -f $scopeName, $scopeFilterText)
            }

            # --- Role assignments
            $rolesNormalized = foreach ($r in @($Role)) { Get-NormalizeRole $r }
            $result.RolesNormalized = @($rolesNormalized)

            foreach ($roleItem in $rolesNormalized) {
                $ShortRoleName = $shortRoleMap[$roleItem]

                $rbacNameBase = Get-SafeName -s ("{0}-{1}" -f $ShortRoleName,$sp.DisplayName) -max 64
                $result.RoleAssignmentsName += $rbacNameBase

                # --- Skip creation if a role assignment with this deterministic name already
                # exists, so re-running against an already-provisioned app is idempotent. Members
                # were already added above regardless of this check.
                $existingAssignments = @(Get-ManagementRoleAssignment -Identity $rbacNameBase -ErrorAction SilentlyContinue)
                if ($existingAssignments.Count -gt 0) {
                    if ($existingAssignments.Count -gt 1) {
                        $existsMsg = "Role assignment '$rbacNameBase' lookup returned $($existingAssignments.Count) entries; expected 1. Resolve duplicate assignments before retrying."
                        $result.Errors += $existsMsg
                        continue
                    }
                    $existingAssignment = $existingAssignments[0]
                    if ([string]$existingAssignment.Role -and ([string]$existingAssignment.Role -ine $roleItem)) {
                        $existsMsg = "Role assignment '$rbacNameBase' already exists but is bound to role '$([string]$existingAssignment.Role)', not '$roleItem'."
                        $result.Errors += $existsMsg
                        continue
                    }
                    $scopeState = Get-RBAC4AppAssignmentScopeState -Assignment $existingAssignment -ManagementScopeName $scopeName -LegacyGroupName $umGroupName
                    switch ($scopeState.State) {
                        'Target' {
                            $existsMsg = "Role assignment '$rbacNameBase' already exists and is scoped to management scope '$scopeName'; skipping creation."
                        }
                        'LegacyGroup' {
                            $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped directly to group '$umGroupName' (legacy -RecipientGroupScope); leaving it as-is. Run Set-RBAC4AppEntry to migrate it to management scope '$scopeName'."
                        }
                        default {
                            $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped to '$($scopeState.CurrentScope)', not management scope '$scopeName'; leaving it as-is. Use Set-RBAC4AppEntry to re-scope it."
                        }
                    }
                    $result.Warnings += $existsMsg
                    Write-Warning -Message $existsMsg
                    $result.RoleAssignments += $existingAssignment
                    continue
                }

                if ($PSCmdlet.ShouldProcess("RBAC role assignment", "Assign '$roleItem' to App '$($sp.DisplayName)' scoped to management scope '$scopeName'")) {
                    $assignment = New-ManagementRoleAssignment `
                        -App $sp.Id `
                        -Role $roleItem `
                        -CustomResourceScope $scopeName `
                        -Name $rbacNameBase `
                        -ErrorAction Stop
                    $result.RoleAssignments += $assignment
                }
            }

            [pscustomobject]$result
            if ($rbacNameBase) {
                $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}_{1}.clixml" -f $rbacNameBase, (Get-Date -Format s).Replace(':', ''))
                [pscustomobject]$result | Export-Clixml $exportPath -Verbose
            }
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
