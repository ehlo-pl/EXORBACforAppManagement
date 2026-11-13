<#
.SYNOPSIS
Validates that a registered application has all the Exchange Online RBAC components that
New-RBAC4AppEntry creates.

.DESCRIPTION
Test-RBAC4AppEntry resolves an application against the Exchange Online service principal pointer
already registered for it (by display name, AppId, or service principal object id - no Microsoft
Graph session is required) and checks that every component New-RBAC4AppEntry provisions is in
place:

  1. the Exchange Online service principal pointer is resolvable (ServicePrincipalExists) - this
     is the same lookup used to resolve the application in the first place, so it is only ever
     false when the whole command fails to resolve an identity and errors out,
  2. for -ScopeKind Group (default), the scope group "{GroupPrefix}-{DisplayName}" (sanitized via
     the same Format-RBAC4AppSafeName rule) exists,
  3. the Exchange Online service principal pointer named exactly "{DisplayName}_SP" - by that
     deterministic name, or by AppId - exists (ExoServicePrincipalExists; distinct from #1, which
     resolves the application by whichever identity the caller supplied), and
  4. for -AssignmentScope ManagementScope, the management scope "{ManagementScopePrefix}-{DisplayName}"
     (or -ManagementScopeName) exists and its RecipientRestrictionFilter matches the one
     New-RBAC4AppEntry would build for the selected -ScopeKind (not checked for RecipientGroupScope,
     which uses no management scope), and
  5. one Exchange Online management role assignment exists per requested role, named the same way
     New-RBAC4AppEntry names them ("{ShortRoleToken}-{DisplayName}"), bound to the expected role
     and per -AssignmentScope: directly to the scope group (RecipientGroupScope, the default for
     -ScopeKind Group) or to that management scope (ManagementScope, -CustomResourceScope).
     Assignments bound the other way are reported in RoleAssignmentsLegacyScoped (direct-to-group
     while ManagementScope is expected) or RoleAssignmentsManagementScoped (management scope while
     RecipientGroupScope is expected) and count as missing; run Set-RBAC4AppEntry with the same
     -AssignmentScope to re-bind them.

When -Members is supplied (ScopeKind Group only), the requested recipients are also verified
against the scope group's membership. The function is read-only: it makes no changes and does not support -WhatIf.

The defaults for -Role and -GroupPrefix mirror New-RBAC4AppEntry, so a plain
"Test-RBAC4AppEntry -RegisteredAppName <app>" validates the default creation.

.PARAMETER AssignmentScope
How the role assignments are expected to be bound for -ScopeKind Group: RecipientGroupScope
(default; directly to the scope group, no management scope) or ManagementScope. Other scope kinds
always use ManagementScope; requesting RecipientGroupScope with them is an error.

.PARAMETER RegisteredAppName
Display name of the registered application or service principal. Default parameter set; must resolve
to exactly one service principal.

.PARAMETER AppId
Application (client) id of the registered application. GUID-validated.

.PARAMETER SpObjectId
Object id of the target service principal. GUID-validated.

.PARAMETER Role
Exchange Online application roles expected to be assigned. Short names such as Mail.Send are
normalized to Application Mail.Send. Defaults to 'Application Mail.Send' (matching New-RBAC4AppEntry).

.PARAMETER Members
Optional recipients expected to be members of the scope group. When supplied, each is
resolved through Get-Recipient and checked against the group's membership. Omit to skip the
membership check.

.PARAMETER GroupPrefix
Prefix used when building the scope group name (matching New-RBAC4AppEntry). When omitted,
defaults to 'USRACo1P'
(CloudMailEnabledSecurityGroup), 'UDLRAo1P' (DistributionList), 'Um365RAo1P' (M365Group), or 'USRAHo1P'
(HybridMailEnabledSecurityGroup) based on -AccessGroupType.

.PARAMETER AccessGroupName
Explicit scope group name to check instead of generating one from GroupPrefix and the
resolved display name. Required when -AccessGroupType is HybridMailEnabledSecurityGroup.

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope (CloudMailEnabledSecurityGroup, DistributionList,
M365Group, or HybridMailEnabledSecurityGroup). Defaults to CloudMailEnabledSecurityGroup (matching
New-RBAC4AppEntry). Controls which cmdlets are used to read the group and its membership, and whether
the send restriction is checked (SendRestricted; not for the hybrid type). The pre-0.9.0 name MailEnabledSecurityGroup is still accepted for HybridMailEnabledSecurityGroup.

.PARAMETER ScopeKind
How the management scope's recipient filter is built: Group (default; MemberOfGroup of the scope
group), Recipients, Tag, or Filter. Mirrors New-RBAC4AppEntry.

.PARAMETER ManagementScopeName
Explicit management scope name. Cannot be combined with -ManagementScopePrefix.

.PARAMETER ManagementScopePrefix
Prefix of the generated management scope name "{Prefix}-{DisplayName}". Default 'MSRAo1P'.

.PARAMETER ScopeRecipients
Mailboxes/UPNs/SMTP addresses expected in the scope filter (-ScopeKind Recipients).

.PARAMETER ScopeTagAttribute
CustomAttribute1..15 expected in the scope filter (-ScopeKind Tag). Default CustomAttribute1.

.PARAMETER ScopeTagValue
Value expected in the scope filter (-ScopeKind Tag). Defaults to the management scope name.

.PARAMETER ScopeFilter
Raw OPATH filter expected on the scope (-ScopeKind Filter).

.EXAMPLE
Test-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App'

Validates the default Application Mail.Send setup for the resolved application and returns a summary
with an IsValid flag.

.EXAMPLE
Test-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' -Role 'Mail.Send','Calendars.Read' -Members 'shared@contoso.com'

Checks the service principal, scope group, management scope, Exchange Online service principal, both
role assignments, and that shared@contoso.com is a group member.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso' -WhatIf; Test-RBAC4AppEntry -RegisteredAppName 'Contoso'

Reports which components are still missing before/after a run.

.OUTPUTS
PSCustomObject

A summary object with the resolved identity, per-component existence flags
(ServicePrincipalExists, ScopeGroupExists, ExoServicePrincipalExists, ManagementScopeExists,
ManagementScopeFilterMatches), the expected/found/missing/legacy-scoped role assignments, optional membership results, an overall IsValid flag, a Missing list, and any
Warnings/Errors. LegacyGroupName is set (with a warning) when the defaults were used and the
application still has its pre-0.9.0 'UDLRAo1P-*' distribution list but no 'USRACo1P-*' group; re-run
with -AccessGroupType DistributionList to validate that list.

SpObjectId comes from the resolved Exchange Online service principal. When it is empty (often an
incomplete Connect-MgGraph / directory read), the object id (GUID) found in an expected role
assignment's EffectiveUserName is used instead; either way a warning is written and added to Warnings.

.NOTES
Requires a connected Exchange Online session only (Get-ServicePrincipal, Get-ConnectionInformation,
Get-UnifiedGroup, Get-ManagementScope, Get-ManagementRoleAssignment, and, when -Members is supplied, Get-Recipient and
Get-UnifiedGroupLinks). No Microsoft Graph session is needed; the application is resolved against
the Exchange Online service principal pointer already registered via Register-EXOServicePrincipal,
New-RBAC4AppEntry, or Invoke-RBAC4AppConfig. Read-only companion to New-RBAC4AppEntry.
#>
function Test-RBAC4AppEntry {
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
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

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role = @('Application Mail.Send'),

        [Parameter(Position = 2)]
        [string[]] $Members,

        [Parameter()]
        [string] $GroupPrefix = $null,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [ValidateSet('CloudMailEnabledSecurityGroup', 'DistributionList', 'M365Group', 'HybridMailEnabledSecurityGroup', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'CloudMailEnabledSecurityGroup',

        [Parameter()]
        [ValidateSet('Group', 'Recipients', 'Tag', 'Filter')]
        [string] $ScopeKind = 'Group',

        [Parameter()]
        [ValidateSet('RecipientGroupScope', 'ManagementScope')]
        [string] $AssignmentScope = 'RecipientGroupScope',

        [Parameter()]
        [ValidateLength(1, 64)]
        [string] $ManagementScopeName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagementScopePrefix = $script:RBAC4AppDefaultManagementScopePrefix,

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
        [string] $ScopeFilter
    )

    begin {
        $shortRoleMap = Get-AppRoleMap

        $tenantid = $null
        try { $tenantid = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1 -ExpandProperty TenantId }
        catch { Write-Verbose -Message "Could not read tenant id from Get-ConnectionInformation: $($_.Exception.Message)" }
    }

    process {
        # Invalid parameter combinations terminate before any work (same as New-/Set-RBAC4AppEntry).
        if ($PSBoundParameters.ContainsKey('ManagementScopeName') -and $PSBoundParameters.ContainsKey('ManagementScopePrefix')) {
            throw "Parameters -ManagementScopeName and -ManagementScopePrefix cannot be used together."
        }
        if ($ScopeKind -eq 'Recipients' -and -not $ScopeRecipients) {
            throw "-ScopeRecipients is required when -ScopeKind is Recipients."
        }
        if ($ScopeKind -eq 'Filter' -and -not $ScopeFilter) {
            throw "-ScopeFilter is required when -ScopeKind is Filter."
        }

        $assignmentScopeInfo = Resolve-RBAC4AppAssignmentScope -ScopeKind $ScopeKind -AssignmentScope $AssignmentScope -BoundParameters $PSBoundParameters
        $AssignmentScope = $assignmentScopeInfo.AssignmentScope
        $isDirectGroup = $AssignmentScope -eq 'RecipientGroupScope'

        $AccessGroupType = ConvertTo-RBAC4AppAccessGroupType -AccessGroupType $AccessGroupType
        if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) {
            $GroupPrefix = Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $AccessGroupType
        }

        $result = [ordered]@{
            ParameterSet            = $PSCmdlet.ParameterSetName
            IdentityInput           = $RegisteredAppName
            ResolvedDisplay         = $null
            AppId                   = $null
            SpObjectId              = $null
            TenantId                = $tenantid
            ScopeKind               = $ScopeKind
            AssignmentScope         = $AssignmentScope
            AccessGroupType         = if ($ScopeKind -eq 'Group') { $AccessGroupType } else { $null }
            ServicePrincipalExists  = $false
            ScopeGroupName          = $null
            ScopeGroupExists        = $false
            LegacyGroupName         = $null
            SendRestricted          = $null
            ExoServicePrincipalName = $null
            ExoServicePrincipalExists = $false
            ManagementScopeName     = $null
            ManagementScopeExists   = $false
            ManagementScopeFilter   = $null
            ManagementScopeExpectedFilter = $null
            ManagementScopeFilterMatches  = $false
            RolesExpected           = @()
            RoleAssignmentsExpected = @()
            RoleAssignmentsFound    = @()
            RoleAssignmentsMissing  = @()
            RoleAssignmentsLegacyScoped = @()
            RoleAssignmentsManagementScoped = @()
            MembersExpected         = @()
            MembersPresent          = @()
            MembersMissing          = @()
            IsValid                 = $false
            Missing                 = @()
            Warnings                = @()
            Errors                  = @()
        }

        try {
            foreach ($ignoredMsg in @(Get-RBAC4AppScopeKindWarning -ScopeKind $ScopeKind -BoundParameters $PSBoundParameters) + @($assignmentScopeInfo.Warnings)) {
                $result.Warnings += $ignoredMsg
            }

            # --- Resolve the service principal depending on parameter set.
            $sp = $null
            switch ($PSCmdlet.ParameterSetName) {
                'BySpObjectId' {
                    $result.IdentityInput = $SpObjectId
                    $sp = Resolve-RBAC4AppServicePrincipal -SpObjectId $SpObjectId
                }
                'ByAppId' {
                    $result.IdentityInput = $AppId
                    $sp = Resolve-RBAC4AppServicePrincipal -AppId $AppId
                }
                'ByName' {
                    $sp = Resolve-RBAC4AppServicePrincipal -DisplayName $RegisteredAppName
                }
            }
            if (-not $sp) {
                throw "No Exchange Online service principal found matching the supplied identity. It must already be registered via Register-EXOServicePrincipal, New-RBAC4AppEntry, or Invoke-RBAC4AppConfig."
            }

            $result.ServicePrincipalExists = $true
            $result.ResolvedDisplay        = $sp.DisplayName
            $result.AppId                  = $sp.AppId

            # An empty object id usually means an incomplete Connect-MgGraph / directory read (not
            # always visible as $null from Get-MgContext). Fall back to the object id Exchange Online
            # carries in an expected role assignment's EffectiveUserName (GUID only) - before the
            # assignee needles are built, since this module's assignments report the raw object id
            # as RoleAssigneeName and would otherwise all look missing.
            $resolvedSpObjectId = [string]$sp.Id
            if (-not $resolvedSpObjectId) {
                $probeNames = foreach ($r in @($Role)) {
                    $probeShort = $shortRoleMap[(ConvertTo-RBAC4AppRoleName -Role $r)]
                    if ($probeShort) { Get-RBAC4AppRoleAssignmentName -ShortRoleName $probeShort -DisplayName $sp.DisplayName -AppId $sp.AppId }
                }
                $probeAssignments = foreach ($probeName in @($probeNames)) {
                    Get-ManagementRoleAssignment -Identity $probeName -ErrorAction SilentlyContinue
                }
                $fallbackId = Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @($probeAssignments | Where-Object { $_ } | ForEach-Object { $_.EffectiveUserName })
                $spIdMsg = if ($fallbackId) {
                    "SpObjectId for '$($sp.DisplayName)' was returned empty (often a sign of an incomplete Connect-MgGraph or directory read); using '$fallbackId' from EffectiveUserName instead."
                }
                else {
                    "SpObjectId for '$($sp.DisplayName)' was returned empty and no expected role assignment's EffectiveUserName holds an object id (GUID); the field is left empty."
                }
                if ($fallbackId) { $resolvedSpObjectId = $fallbackId }
                Write-Warning -Message $spIdMsg
                $result.Warnings += $spIdMsg
            }
            $result.SpObjectId             = if ($resolvedSpObjectId) { $resolvedSpObjectId } else { $null }

            # --- Scope group existence (same name rule as New-RBAC4AppEntry; read cmdlet per type).
            # Only relevant for -ScopeKind Group; other kinds have no backing group.
            $umGroupName = $null
            $group = $null
            if ($ScopeKind -eq 'Group') {
            #REINDENT-START
            if ($PSBoundParameters.ContainsKey('AccessGroupName')) {
                $umGroupName = $AccessGroupName
            }
            elseif ($AccessGroupType -eq 'HybridMailEnabledSecurityGroup') {
                throw "-AccessGroupName is required when -AccessGroupType is HybridMailEnabledSecurityGroup."
            }
            else {
                $umGroupName = Get-RBAC4AppScopeGroupName -Prefix $GroupPrefix -DisplayName $sp.DisplayName -AppId $sp.AppId
            }
            $result.ScopeGroupName = $umGroupName
            # Pre-0.9.0 guard: with the defaults, an app that still has its 'UDLRAo1P-*' list (the
            # default before 0.9.0) but no 'USRACo1P-*' group is checked against the wrong group.
            $legacyGroup = Get-RBAC4AppLegacyScopeGroupName -BoundParameters $PSBoundParameters -AccessGroupType $AccessGroupType -CurrentGroupName $umGroupName -DisplayName $sp.DisplayName -AppId $sp.AppId
            if ($legacyGroup) {
                $result.LegacyGroupName = $legacyGroup
                $legacyMsg = "Scope group '$legacyGroup' (a DistributionList, the default before 0.9.0) exists for this application but '$umGroupName' does not; this run checked '$umGroupName'. Re-run with -AccessGroupType DistributionList to validate the existing list."
                $result.Warnings += $legacyMsg
                Write-Warning -Message $legacyMsg
            }
            $group = switch ($AccessGroupType) {
                'CloudMailEnabledSecurityGroup' { Get-DistributionGroup -Identity $umGroupName -ErrorAction SilentlyContinue }
                'DistributionList'              { Get-DistributionGroup -Identity $umGroupName -ErrorAction SilentlyContinue }
                'HybridMailEnabledSecurityGroup' { Get-Recipient -Identity $umGroupName -ErrorAction SilentlyContinue }
                default                    { Get-UnifiedGroup -Identity $umGroupName -ErrorAction SilentlyContinue }
            }
            if ($group -and $AccessGroupType -eq 'HybridMailEnabledSecurityGroup' -and
                ([string]$group.RecipientTypeDetails -notin $script:RBAC4AppSecurityGroupRecipientTypes)) {
                # Found, but not a mail-enabled security group: not a valid scope source.
                $result.Missing += "$AccessGroupType '$umGroupName' (wrong recipient type '$([string]$group.RecipientTypeDetails)')"
            }
            elseif ($group) {
                $result.ScopeGroupExists = $true
                # Send restriction: checked for module-managed groups only (never a hybrid group). A
                # group that can still receive mail is a warning, not a missing component.
                if ($AccessGroupType -in $script:RBAC4AppCreatableGroupTypes) {
                    $result.SendRestricted = Test-RBAC4AppScopeGroupSendRestriction -Group $group
                    if ($result.SendRestricted -eq $false) {
                        $sendMsg = Get-RBAC4AppSendRestrictionWarning -Name $umGroupName
                        $result.Warnings += $sendMsg
                        Write-Warning -Message $sendMsg
                    }
                }
            }
            else {
                $result.Missing += "$AccessGroupType '$umGroupName'"
            }
            #REINDENT-END
            }

            # --- Exchange Online service principal pointer existence (matched by AppId, then name).
            $exoSpDisplay = "{0}_SP" -f $sp.DisplayName
            $result.ExoServicePrincipalName = $exoSpDisplay
            $exoSp = @(Get-ServicePrincipal -ErrorAction SilentlyContinue) |
                Where-Object { $_ -and (($_.AppId -eq $sp.AppId) -or ($_.DisplayName -eq $exoSpDisplay)) } |
                Select-Object -First 1
            if ($exoSp) {
                $result.ExoServicePrincipalExists = $true
            }
            else {
                $result.Missing += "Exchange Online service principal '$exoSpDisplay'"
            }

            # --- Management scope existence and filter (same name/filter rules as New-RBAC4AppEntry).
            # Skipped for RecipientGroupScope, which binds the assignments without a management scope.
            $scopeName = Get-RBAC4AppManagementScopeName -DisplayName $sp.DisplayName -Prefix $ManagementScopePrefix -Name $ManagementScopeName -AppId $sp.AppId
            if (-not $isDirectGroup) {
                $result.ManagementScopeName = $scopeName
                $scopeObj = $null
                try { $scopeObj = Get-ManagementScope -Identity $scopeName -ErrorAction Stop | Select-Object -First 1 }
                catch { Write-Verbose -Message "Management scope '$scopeName' not found: $($_.Exception.Message)" }

                $expectedFilter = $null
                if ($ScopeKind -ne 'Group' -or $group) {
                    $filterArgs = @{
                        ScopeKind              = $ScopeKind
                        GroupIdentity          = $umGroupName
                        GroupDistinguishedName = if ($group) { [string]$group.DistinguishedName } else { $null }
                        Recipients             = $ScopeRecipients
                        TagAttribute           = $ScopeTagAttribute
                        TagValue               = if ($ScopeTagValue) { $ScopeTagValue } else { $scopeName }
                        Filter                 = $ScopeFilter
                    }
                    $fWarnings = @()
                    try { $expectedFilter = ConvertTo-RBAC4AppRecipientFilter @filterArgs -WarningVariable fWarnings -WarningAction SilentlyContinue }
                    catch { $result.Warnings += "Could not build the expected management scope filter: $($_.Exception.Message)" }
                    foreach ($w in @($fWarnings)) { if ($w) { $result.Warnings += [string]$w.Message } }
                }
                $result.ManagementScopeExpectedFilter = $expectedFilter

                if ($scopeObj) {
                    $result.ManagementScopeExists = $true
                    $currentFilter = [string]$scopeObj.RecipientFilter
                    if (-not $currentFilter) { $currentFilter = [string]$scopeObj.RecipientRestrictionFilter }
                    $result.ManagementScopeFilter = $currentFilter
                    if ($expectedFilter -and (Test-RBAC4AppRecipientFilterEqual -Reference $currentFilter -Difference $expectedFilter)) {
                        $result.ManagementScopeFilterMatches = $true
                    }
                    else {
                        $result.Missing += "Management scope '$scopeName' filter (expected: $expectedFilter; current: $currentFilter)"
                    }
                }
                else {
                    $result.Missing += "Management scope '$scopeName'"
                }
            }

            # --- Role assignment existence, by the deterministic name New-RBAC4AppEntry builds.
            $rolesNormalized = foreach ($r in @($Role)) { ConvertTo-RBAC4AppRoleName -Role $r }
            $result.RolesExpected = @($rolesNormalized)
            $assigneeNeedles = @($sp.DisplayName, ("{0}_SP" -f $sp.DisplayName), $sp.AppId, $resolvedSpObjectId) | Where-Object { $_ }

            foreach ($roleItem in $rolesNormalized) {
                $shortRoleName = $shortRoleMap[$roleItem]
                if (-not $shortRoleName) {
                    $result.Warnings += "Role '$roleItem' is not a recognized application role; skipping its assignment check."
                    continue
                }

                $expectedName = Get-RBAC4AppRoleAssignmentName -ShortRoleName $shortRoleName -DisplayName $sp.DisplayName -AppId $sp.AppId
                $result.RoleAssignmentsExpected += $expectedName

                $assignment = Get-ManagementRoleAssignment -Identity $expectedName -ErrorAction SilentlyContinue
                $assignmentMatches = $false
                $assignmentLegacy = $false
                $assignmentManagementScoped = $false
                $targetState = if ($isDirectGroup) { 'LegacyGroup' } else { 'Target' }
                foreach ($candidate in @($assignment | Where-Object { $_ })) {
                    $assignee = [string]$candidate.RoleAssigneeName
                    $assigneeMatches = $false
                    foreach ($n in $assigneeNeedles) {
                        if ($assignee -and $assignee -like "*$n*") { $assigneeMatches = $true; break }
                    }

                    if (([string]$candidate.Role -ne $roleItem) -or -not $assigneeMatches) { continue }
                    $state = (Get-RBAC4AppAssignmentScopeState -Assignment $candidate -ManagementScopeName $scopeName -LegacyGroupName $umGroupName).State
                    if ($state -eq $targetState) {
                        $assignmentMatches = $true
                        break
                    }
                    if ($state -eq 'LegacyGroup') { $assignmentLegacy = $true }
                    if ($state -eq 'Target') { $assignmentManagementScoped = $true }
                }

                if ($assignmentMatches) {
                    $result.RoleAssignmentsFound += $expectedName
                }
                elseif ($assignmentLegacy -and -not $isDirectGroup) {
                    $result.RoleAssignmentsMissing += $expectedName
                    $result.RoleAssignmentsLegacyScoped += $expectedName
                    $result.Missing += "Role assignment '$expectedName' ($roleItem) is scoped directly to group '$umGroupName'; run Set-RBAC4AppEntry -AssignmentScope ManagementScope to move it onto management scope '$scopeName'"
                }
                elseif ($assignmentManagementScoped -and $isDirectGroup) {
                    $result.RoleAssignmentsMissing += $expectedName
                    $result.RoleAssignmentsManagementScoped += $expectedName
                    $result.Missing += "Role assignment '$expectedName' ($roleItem) is scoped to management scope '$scopeName'; run Set-RBAC4AppEntry to bind it directly to group '$umGroupName'"
                }
                elseif ($isDirectGroup) {
                    $result.RoleAssignmentsMissing += $expectedName
                    $result.Missing += "Role assignment '$expectedName' ($roleItem) bound directly to group '$umGroupName'"
                }
                else {
                    $result.RoleAssignmentsMissing += $expectedName
                    $result.Missing += "Role assignment '$expectedName' ($roleItem) bound to management scope '$scopeName'"
                }
            }

            # --- Optional membership check.
            if ($ScopeKind -eq 'Group' -and $PSBoundParameters.ContainsKey('Members')) {
                $requested = @($Members | Where-Object { $_ })
                $result.MembersExpected = $requested

                if ($result.ScopeGroupExists) {
                    $links = if ($AccessGroupType -eq 'M365Group') {
                        @(Get-UnifiedGroupLinks -Identity $umGroupName -LinkType Members -ErrorAction SilentlyContinue)
                    }
                    else {
                        @(Get-DistributionGroupMember -Identity $umGroupName -ErrorAction SilentlyContinue)
                    }
                    $linkAddresses = @($links | ForEach-Object { [string]$_.PrimarySmtpAddress; [string]$_.Name } | Where-Object { $_ })

                    foreach ($member in $requested) {
                        $rec = Get-Recipient -Identity $member -ErrorAction SilentlyContinue
                        $needle = if ($rec) { [string]$rec.PrimarySmtpAddress } else { [string]$member }
                        if ($linkAddresses -contains $needle -or ($rec -and ($linkAddresses -contains [string]$rec.Name))) {
                            $result.MembersPresent += $needle
                        }
                        else {
                            $result.MembersMissing += $needle
                            $result.Missing += "Group member '$needle'"
                        }
                    }
                }
                else {
                    foreach ($member in $requested) {
                        $result.MembersMissing += [string]$member
                        $result.Missing += "Group member '$member' (group missing)"
                    }
                }
            }

            $result.IsValid = $result.ServicePrincipalExists -and
                              (($ScopeKind -ne 'Group') -or $result.ScopeGroupExists) -and
                              ($isDirectGroup -or ($result.ManagementScopeExists -and $result.ManagementScopeFilterMatches)) -and
                              $result.ExoServicePrincipalExists -and
                              ($result.RoleAssignmentsMissing.Count -eq 0) -and
                              ($result.MembersMissing.Count -eq 0)

            [pscustomobject]$result
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
