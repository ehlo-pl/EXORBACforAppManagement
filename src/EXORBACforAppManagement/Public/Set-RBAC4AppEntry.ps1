<#
.SYNOPSIS
Reconciles a registered application's Exchange Online RBAC scoping to the desired state: repairs
missing components, tops up the Unified Group membership, and can move the role assignments to a
different scoping group.

.DESCRIPTION
Set-RBAC4AppEntry is the "make it so" companion to Test-RBAC4AppEntry (which only reports) and
New-RBAC4AppEntry (which creates everything from scratch). It resolves the application against the
Exchange Online service principal pointer already registered for it (by display name, AppId, or
service principal object id) - no Microsoft Graph session is required - and brings the components
New-RBAC4AppEntry provisions into the desired state, changing only what is needed:

  1. the scoped Unified Group ("{GroupPrefix}-{DisplayName}", sanitized via Get-SafeName) is created
     if it is missing (delegated to New-RBAC4AppUnifiedGroup),
  2. the Exchange Online service principal pointer ("{DisplayName}_SP") is created if it is missing
     (delegated to Register-EXOServicePrincipal),
  3. the requested -Members are added to the group if they are not already members (additive only -
     existing members are never removed), and
  4. one Exchange Online management role assignment exists per requested role, named the same way
     New-RBAC4AppEntry names them ("{ShortRoleToken}-{DisplayName}") and scoped to the target group.
     A missing assignment is created; an assignment that exists but is scoped to a different group is
     re-scoped (removed and recreated with the same name) - this is how the scoping group is changed.

Changing the scoping group: supply -NewGroupName (an explicit group name) or -NewGroupPrefix (builds
"{NewGroupPrefix}-{DisplayName}"). The target group is ensured to exist and the role assignments are
re-scoped onto it. The old group is left in place (use Remove-RBAC4AppEntry to tear it down once it
is no longer in use); members are not migrated.

For an application that has never been registered in Exchange Online (its service principal pointer
does not exist yet), none of -RegisteredAppName, -AppId, or -SpObjectId alone is enough to resolve
it: supply all three together (-AppId, -SpObjectId, and -RegisteredAppName as the display name) to
bootstrap the pointer as part of reconciliation, or provision it first with New-RBAC4AppConfig +
Invoke-RBAC4AppConfig.

The function supports -WhatIf and -Confirm through SupportsShouldProcess (ConfirmImpact High), so each
change is confirmed interactively unless -Confirm:$false / -Force-style suppression is used. Under
-WhatIf no changes are made and IsValid reflects the actual (unchanged) state.

.PARAMETER RegisteredAppName
Display name of the registered application. Used to resolve an already-registered Exchange Online
service principal pointer by name, and as the display name when bootstrapping a never-before-seen
application together with -AppId and -SpObjectId.

.PARAMETER AppId
Application (client) id of the registered application. GUID-validated.

.PARAMETER SpObjectId
Object id of the target service principal. GUID-validated.

.PARAMETER Role
Exchange Online application roles to ensure are assigned. Short names such as Mail.Send are normalized
to Application Mail.Send. Defaults to 'Application Mail.Send' (matching New-RBAC4AppEntry).

.PARAMETER Members
Optional recipients to ensure are members of the scoped Unified Group. Each is resolved through
Get-Recipient and added if absent. Membership is additive: members already present are left as-is and
nothing is removed.

.PARAMETER ManagedBy
Recipient assigned as the Unified Group owner when the group must be created. Defaults to
'GraphAPI-Dummy-owner' (matching New-RBAC4AppEntry).

.PARAMETER GroupPrefix
Prefix used when building the current Unified Group name. Defaults to 'Um365RAo1' (matching
New-RBAC4AppEntry).

.PARAMETER AccessGroupName
Explicit current scope group name to reconcile instead of generating one from GroupPrefix and
the resolved display name. Required when -AccessGroupType is MailEnabledSecurityGroup.

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope (M365Group, DistributionList, or
MailEnabledSecurityGroup). Defaults to M365Group. A MailEnabledSecurityGroup is
on-prem/hybrid-synced: it is never created or modified, and -Members, -ManagedBy, and
-BootstrapMember are all ignored (membership and ownership are managed on-premises).

.PARAMETER BootstrapMember
Optional initial member passed to New-RBAC4AppUnifiedGroup when the group must be created. Defaults
to 'GraphAPI-Dummy'.

.PARAMETER NewGroupPrefix
Optional. Switch the role assignments to a group named "{NewGroupPrefix}-{DisplayName}" (sanitized).
Ignored when -NewGroupName is supplied.

.PARAMETER NewGroupName
Optional. Switch the role assignments to this explicit group name (sanitized via Get-SafeName). Takes
precedence over -NewGroupPrefix.

.EXAMPLE
Set-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -WhatIf -Verbose

Shows which missing components would be (re)created for the default Application Mail.Send setup,
without making changes.

.EXAMPLE
Set-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Members 'shared@contoso.com'

Ensures every component exists and adds shared@contoso.com to the scoped group if it is not already a
member.

.EXAMPLE
Set-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' -NewGroupPrefix 'Um365Prod'

Re-scopes the application's role assignments onto the 'Um365Prod-...' group (creating it if needed).

.OUTPUTS
PSCustomObject

A summary object with the resolved identity, the current and target group names, a GroupChanged flag,
which components were created, the requested/added members and the final group membership
(MembersFinal), and the role assignments partitioned into created / re-scoped / unchanged, an overall
IsValid flag, and any Warnings/Errors.

.NOTES
Requires a connected Exchange Online session only (Get-ServicePrincipal, Get-ConnectionInformation,
Get-UnifiedGroup, Get-UnifiedGroupLinks, Get-DistributionGroupMember, Get-Recipient,
Get-ManagementRoleAssignment, New-ManagementRoleAssignment, Remove-ManagementRoleAssignment, plus
the cmdlets used by the delegated New-RBAC4AppUnifiedGroup / Register-EXOServicePrincipal). No
Microsoft Graph session is needed. Reconcile companion to Test-RBAC4AppEntry and New-RBAC4AppEntry.
#>
function Set-RBAC4AppEntry {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
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
        [ValidateNotNullOrEmpty()]
        [string[]] $Role = @('Application Mail.Send'),

        [Parameter(Position = 2)]
        [string[]] $Members,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagedBy = 'GraphAPI-Dummy-owner',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $GroupPrefix = 'Um365RAo1',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'M365Group',

        [Parameter()]
        [string] $BootstrapMember = 'GraphAPI-Dummy',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $NewGroupPrefix,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $NewGroupName
    )

    begin {
        $shortRoleMap = Get-AppRoleMap

        $tenantid = $null
        try { $tenantid = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1 -ExpandProperty TenantId }
        catch { Write-Verbose -Message "Could not read tenant id from Get-ConnectionInformation: $($_.Exception.Message)" }
    }

    process {
        if (-not $PSBoundParameters.ContainsKey('RegisteredAppName') -and
            -not $PSBoundParameters.ContainsKey('AppId') -and
            -not $PSBoundParameters.ContainsKey('SpObjectId')) {
            throw "One of -RegisteredAppName, -AppId, or -SpObjectId must be supplied."
        }

        $result = [ordered]@{
            ParameterSet              = $null
            IdentityInput             = $null
            ResolvedDisplay           = $null
            AppId                     = $null
            SpObjectId                = $null
            TenantId                  = $tenantid
            AccessGroupType           = $AccessGroupType
            CurrentGroupName          = $null
            TargetGroupName           = $null
            GroupChanged              = $false
            ScopeGroupExisted         = $false
            ScopeGroupCreated         = $false
            ExoServicePrincipalName   = $null
            ExoServicePrincipalExisted = $false
            ExoServicePrincipalCreated = $false
            MembersRequested          = @()
            MembersAdded              = @()
            MembersAlreadyPresent     = @()
            MembersFinal              = @()
            FilteredMembers           = @()
            RolesNormalized           = @()
            RoleAssignmentsCreated    = @()
            RoleAssignmentsRescoped   = @()
            RoleAssignmentsUnchanged  = @()
            IsValid                   = $false
            Warnings                  = @()
            Errors                    = @()
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

            # --- Determine the current and target scope group names (same name rule as New-RBAC4AppEntry).
            # A MailEnabledSecurityGroup is on-prem/hybrid-synced: its name is referenced, never generated.
            if ($PSBoundParameters.ContainsKey('AccessGroupName')) {
                $currentGroup = $AccessGroupName
            }
            elseif ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                throw "-AccessGroupName is required when -AccessGroupType is MailEnabledSecurityGroup."
            }
            else {
                $currentGroup = Get-SafeName -s ("{0}-{1}" -f $GroupPrefix, $sp.DisplayName)
            }

            if ($PSBoundParameters.ContainsKey('NewGroupName')) {
                $targetGroup = if ($AccessGroupType -eq 'MailEnabledSecurityGroup') { $NewGroupName } else { Get-SafeName -s $NewGroupName }
            }
            elseif ($PSBoundParameters.ContainsKey('NewGroupPrefix')) {
                if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                    throw "-NewGroupPrefix cannot be used with -AccessGroupType MailEnabledSecurityGroup; on-prem/hybrid-synced group names are referenced, not generated. Use -NewGroupName with an existing group."
                }
                $targetGroup = Get-SafeName -s ("{0}-{1}" -f $NewGroupPrefix, $sp.DisplayName)
            }
            else {
                $targetGroup = $currentGroup
            }
            $result.CurrentGroupName = $currentGroup
            $result.TargetGroupName  = $targetGroup
            $result.GroupChanged     = ($targetGroup -ne $currentGroup)

            # --- Ensure the target scope group exists (delegated to New-RBAC4AppScopeGroup; read per type).
            $group = switch ($AccessGroupType) {
                'DistributionList'         { Get-DistributionGroup -Identity $targetGroup -ErrorAction SilentlyContinue }
                'MailEnabledSecurityGroup' { Get-Recipient -Identity $targetGroup -ErrorAction SilentlyContinue }
                default                    { Get-UnifiedGroup -Identity $targetGroup -ErrorAction SilentlyContinue }
            }
            $result.ScopeGroupExisted = [bool]$group
            if (-not $group) {
                if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                    # On-prem/hybrid-synced groups cannot be created in the cloud.
                    $result.Errors += "MailEnabledSecurityGroup '$targetGroup' does not exist and cannot be created (it is mastered on-premises)."
                }
                elseif ($PSCmdlet.ShouldProcess($targetGroup, "Create $AccessGroupType")) {
                    $ugResult = New-RBAC4AppScopeGroup -AccessGroupType $AccessGroupType -Name $targetGroup -ManagedBy $ManagedBy -BootstrapMember $BootstrapMember -WarningVariable ugWarnings
                    foreach ($w in $ugWarnings) {
                        if ([string]$w.Message -like '*already exists*') { $result.Warnings += [string]$w.Message }
                    }
                    if ($ugResult) {
                        $result.ScopeGroupCreated = $true
                        $group = $ugResult.Group
                    }
                }
            }

            # --- Ensure the Exchange Online service principal pointer (matched by AppId, then name).
            $exoSpDisplay = "{0}_SP" -f $sp.DisplayName
            $result.ExoServicePrincipalName = $exoSpDisplay
            $exoSp = @(Get-ServicePrincipal -ErrorAction SilentlyContinue) |
                Where-Object { $_ -and (($_.AppId -eq $sp.AppId) -or ($_.DisplayName -eq $exoSpDisplay)) } |
                Select-Object -First 1
            if ($exoSp) {
                $result.ExoServicePrincipalExisted = $true
            }
            elseif ($PSCmdlet.ShouldProcess($exoSpDisplay, 'Create Exchange Online service principal')) {
                $null = Register-EXOServicePrincipal -AppId $sp.AppId -ObjectId $sp.Id -DisplayName $exoSpDisplay
                $result.ExoServicePrincipalCreated = $true
            }

            # --- Read the target group's current membership once (all types, read-only): used for
            # the "already present" check below and to seed MembersFinal, reused rather than
            # re-queried after any additions (EXO reads can lag writes).
            $existingLinks = if ($AccessGroupType -eq 'M365Group') {
                @(Get-UnifiedGroupLinks -Identity $targetGroup -LinkType Members -ErrorAction SilentlyContinue)
            }
            else {
                @(Get-DistributionGroupMember -Identity $targetGroup -ErrorAction SilentlyContinue)
            }
            $existingMemberIdentities = @($existingLinks | ForEach-Object {
                    if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
                } | Where-Object { $_ } | Select-Object -Unique)

            # --- MailEnabledSecurityGroup is on-prem/hybrid-synced: it is never created or modified
            # here, so warn about any group-modifying parameter that was requested but ignored.
            if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                if ($ManagedBy -and $ManagedBy -ne 'GraphAPI-Dummy-owner') {
                    $skipOwnerMsg = "Ownership of MailEnabledSecurityGroup '$targetGroup' is managed on-premises; -ManagedBy was ignored."
                    $result.Warnings += $skipOwnerMsg
                    Write-Warning -Message $skipOwnerMsg
                }
                if ($BootstrapMember -and $BootstrapMember -ne 'GraphAPI-Dummy') {
                    $skipBootstrapMsg = "Initial membership of MailEnabledSecurityGroup '$targetGroup' is managed on-premises; -BootstrapMember was ignored."
                    $result.Warnings += $skipBootstrapMsg
                    Write-Warning -Message $skipBootstrapMsg
                }
            }

            # --- Members (additive): add any requested member not already in the target group.
            # Skipped for MailEnabledSecurityGroup: membership is mastered on-premises.
            if ($PSBoundParameters.ContainsKey('Members') -and $AccessGroupType -eq 'MailEnabledSecurityGroup') {
                $result.MembersRequested = @($Members | Where-Object { $_ })
                $skipMembersMsg = "Membership of MailEnabledSecurityGroup '$targetGroup' is managed on-premises; -Members was ignored."
                $result.Warnings += $skipMembersMsg
                Write-Warning -Message $skipMembersMsg
            }
            elseif ($PSBoundParameters.ContainsKey('Members')) {
                $requested = @($Members | Where-Object { $_ })
                $result.MembersRequested = $requested

                $currentUserUpn = $null
                try { $currentUserUpn = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1 -ExpandProperty UserPrincipalName }
                catch {
                    $result.Warnings += "Could not retrieve current connection user via Get-ConnectionInformation; connection user filtering will be skipped. Error: $($_.Exception.Message)"
                }

                $linkAddresses = @($existingLinks | ForEach-Object { [string]$_.PrimarySmtpAddress; [string]$_.Name } | Where-Object { $_ })

                foreach ($member in $requested) {
                    if ($currentUserUpn -and ($member -ieq $currentUserUpn)) {
                        $result.FilteredMembers += [string]$member
                        $filterWarning = "Current connection user '$currentUserUpn' was found in the members list and has been filtered out."
                        $result.Warnings += $filterWarning
                        Write-Warning -Message $filterWarning
                        continue
                    }

                    $rec = Get-Recipient -Identity $member -ErrorAction SilentlyContinue
                    if (-not $rec) {
                        $result.Warnings += "Recipient not found for '$member' (skipped)."
                        continue
                    }
                    $needle = [string]$rec.PrimarySmtpAddress

                    if (($linkAddresses -contains $needle) -or ($linkAddresses -contains [string]$rec.Name)) {
                        $result.MembersAlreadyPresent += $needle
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess("$AccessGroupType $targetGroup", "Add member $needle")) {
                        if ($AccessGroupType -eq 'DistributionList') {
                            Add-DistributionGroupMember -Identity $targetGroup -Member $needle -ErrorAction Stop
                        }
                        else {
                            Add-UnifiedGroupLinks -Identity $targetGroup -LinkType Members -Links $needle -ErrorAction Stop
                        }
                        $result.MembersAdded += $needle
                    }
                }
            }

            $result.MembersFinal = @($existingMemberIdentities + $result.MembersAdded | Select-Object -Unique)

            # --- Role assignments: ensure one per role, scoped to the target group.
            $rolesNormalized = foreach ($r in @($Role)) { Get-NormalizeRole $r }
            $result.RolesNormalized = @($rolesNormalized)

            $rolesAllSatisfied = $true
            foreach ($roleItem in $rolesNormalized) {
                $shortRoleName = $shortRoleMap[$roleItem]
                if (-not $shortRoleName) {
                    $result.Warnings += "Role '$roleItem' is not a recognized application role; skipping its assignment."
                    $rolesAllSatisfied = $false
                    continue
                }

                $rbacName = Get-SafeName -s ("{0}-{1}" -f $shortRoleName, $sp.DisplayName) -max 63

                try {
                    $existing = Get-ManagementRoleAssignment -Identity $rbacName -ErrorAction SilentlyContinue
                    $scopedToTarget = $existing -and
                        ([string]$existing.RecipientWriteScope -in @('Group','CustomRecipientScope')) -and
                        ([string]$existing.CustomRecipientWriteScope -eq $targetGroup)

                    if ($existing -and $scopedToTarget) {
                        # Already in desired state.
                        $result.RoleAssignmentsUnchanged += $rbacName
                    }
                    elseif ($existing) {
                        # Exists but scoped elsewhere (repair / group change): re-scope by recreating.
                        $action = "Re-scope role '$roleItem' for App '$($sp.DisplayName)' to '$targetGroup'"
                        if ($PSCmdlet.ShouldProcess($rbacName, $action)) {
                            Remove-ManagementRoleAssignment -Identity $rbacName -Confirm:$false -ErrorAction Stop
                            $null = New-ManagementRoleAssignment -App $sp.Id -Role $roleItem -RecipientGroupScope $targetGroup -Name $rbacName -ErrorAction Stop
                            $result.RoleAssignmentsRescoped += $rbacName
                        }
                        else {
                            $rolesAllSatisfied = $false
                        }
                    }
                    else {
                        # Missing: create.
                        $action = "Assign '$roleItem' to App '$($sp.DisplayName)' scoped to '$targetGroup'"
                        if ($PSCmdlet.ShouldProcess($rbacName, $action)) {
                            $null = New-ManagementRoleAssignment -App $sp.Id -Role $roleItem -RecipientGroupScope $targetGroup -Name $rbacName -ErrorAction Stop
                            $result.RoleAssignmentsCreated += $rbacName
                        }
                        else {
                            $rolesAllSatisfied = $false
                        }
                    }
                }
                catch {
                    $result.Errors += "Failed to reconcile role assignment '$rbacName' ($roleItem): $($_.Exception.Message)"
                    $rolesAllSatisfied = $false
                }
            }

            # IsValid: every component is present after this run (true unchanged state, or actually applied).
            $groupOk = $result.ScopeGroupExisted -or $result.ScopeGroupCreated
            $exoOk   = $result.ExoServicePrincipalExisted -or $result.ExoServicePrincipalCreated
            $result.IsValid = ($result.Errors.Count -eq 0) -and $groupOk -and $exoOk -and $rolesAllSatisfied

            [pscustomobject]$result
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
