<#
.SYNOPSIS
Creates or updates Exchange Online RBAC scoping for an Entra application service principal.

.DESCRIPTION
New-RBAC4AppEntry resolves an application against the Exchange Online service principal pointer
already registered for it (by display name, AppId, or service principal object id), creates the
scoped Unified Group when needed, adds requested members, ensures the Exchange Online service
principal exists, and creates Exchange Online RBAC role assignments for the application.

Resolution is Exchange-Online-only: it looks up the pointer Register-EXOServicePrincipal creates
(via Get-ServicePrincipal), not the Entra service principal itself, so no Microsoft Graph session
is required. For an application that has never been registered in Exchange Online, none of
-RegisteredAppName, -AppId, or -SpObjectId alone is enough to create that pointer (AppId and the
service principal object id cannot be derived from each other without Graph): supply all three
together (-AppId, -SpObjectId, and -RegisteredAppName as the display name) to bootstrap it in one
call, or provision it in two Graph/EXO-separated steps with New-RBAC4AppConfig +
Invoke-RBAC4AppConfig instead.

Unified Group creation/configuration is delegated to New-RBAC4AppUnifiedGroup and the
Exchange Online service principal step to Register-EXOServicePrincipal. Every creation step is
idempotent: the scope group, the EXO service principal, and each role assignment are only created
if a matching one does not already exist, so re-running against an already-provisioned application
is safe - a role assignment that already exists and is scoped to the same group is left alone (a
warning notes it was skipped); requested members are still added to the group regardless.

The function supports -WhatIf and -Confirm through SupportsShouldProcess.

.PARAMETER RegisteredAppName
Display name of the registered application. Used to resolve an already-registered Exchange Online
service principal pointer by name, and as the display name when bootstrapping a never-before-seen
application together with -AppId and -SpObjectId.

.PARAMETER AppId
Application (client) id of the registered application.

.PARAMETER SpObjectId
Object id of the target service principal.

.PARAMETER Members
Recipients to add to the Unified Group scope. Values must resolve through
Get-Recipient. The default placeholder value is GraphAPI-Dummy.

.PARAMETER Role
Exchange Online application roles to assign. Short names such as Mail.Send are
normalized to Application Mail.Send where supported.

.PARAMETER ManagedBy
Recipient that will be assigned as the Unified Group owner.

.PARAMETER GroupPrefix
Prefix used when building the Unified Group name.

.PARAMETER AccessGroupName
Explicit scope group name to use for RBAC scoping instead of generating a name from
GroupPrefix and the resolved service principal display name. Cannot be combined with
an explicit GroupPrefix value. Required when -AccessGroupType is MailEnabledSecurityGroup
(on-prem/hybrid-synced groups already have their own name and are never generated).

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope. One of:
  - M365Group (default): create/configure a Microsoft 365 Unified Group.
  - DistributionList: create/configure an Exchange-Online-only distribution list.
  - MailEnabledSecurityGroup: reference an existing on-prem/hybrid-synced mail-enabled
    security group. The group is never created or modified (it is mastered on-premises),
    -AccessGroupName is required, and -Members, -ManagedBy, and -BootstrapMember are all
    ignored (membership and ownership are managed on-premises).

.PARAMETER BootstrapMember
Optional initial member passed during Unified Group creation.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Verbose -WhatIf

Shows the planned service principal resolution, Unified Group creation, and RBAC
assignment actions without making changes.

.EXAMPLE
New-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' -Members 'sharedmailbox@contoso.com' -Role 'Mail.Send' -Verbose

Resolves the application by AppId, ensures the scoped Unified Group exists, adds the
recipient, and creates the Application Mail.Send role assignment.

.EXAMPLE
New-RBAC4AppEntry -SpObjectId '11111111-2222-3333-4444-555555555555' -Role 'Application Calendars.Read','Application Contacts.Read' -GroupPrefix 'Um365Prod'

Uses the service principal object id directly and creates multiple application role
assignments scoped to the generated Unified Group.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupName 'RBAC-AppScope-ContosoMail' -Role 'Mail.Send'

Uses an explicit Unified Group name for scoping and assigns the requested RBAC role to
the application against that group.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType DistributionList -Members 'shared@contoso.com' -Role 'Mail.Send'

Creates an Exchange-Online-only distribution list as the scope group, adds the member, and
assigns the role scoped to that list.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-MailApp-Scope' -Role 'Mail.Send'

Scopes the role assignment to an existing on-prem/hybrid-synced mail-enabled security group.
The group is not created and its membership (managed on-premises) is left untouched.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AppId '11111111-2222-3333-4444-555555555555' -SpObjectId '66666666-7777-8888-9999-000000000000' -Role 'Mail.Send'

Bootstraps the Exchange Online service principal pointer for an application that has never been
registered before, from explicit identifiers, then proceeds as a normal creation.

.OUTPUTS
PSCustomObject

Returns a summary object with resolved identity, Unified Group name, normalized roles,
assignment names, warnings, and errors.

.NOTES
Requires a connected Exchange Online session only (Get-ServicePrincipal, Get-ConnectionInformation,
New-ServicePrincipal, Get-UnifiedGroup, Set-UnifiedGroup, Add-UnifiedGroupLinks,
Get-UnifiedGroupLinks, Get-DistributionGroupMember, Get-ManagementRoleAssignment, and
New-ManagementRoleAssignment). No Microsoft Graph session is needed.
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
        [string] $ManagedBy = "GraphAPI-Dummy-owner",

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $GroupPrefix = "Um365RAo1",

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'M365Group',

        # Optional placeholder member (dont validate as email)
        [Parameter()]
        [string] $BootstrapMember = "GraphAPI-Dummy"
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
            AccessGroupType   = $AccessGroupType
            ScopeGroupName    = $null
            OwnerRequested    = $ManagedBy
            OwnerAdded        = $null
            MembersRequested  = @($Members)
            MembersAdded      = @()
            MembersFinal      = @()
            FilteredMembers   = @()
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

            # --- Resolve the scope group name. A MailEnabledSecurityGroup is on-prem/hybrid-synced:
            # it already has its own name and is never generated, so -AccessGroupName is required.
            if ($PSBoundParameters.ContainsKey('AccessGroupName')) {
                $umGroupName = $AccessGroupName
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
            $ugResult = New-RBAC4AppScopeGroup -AccessGroupType $AccessGroupType -Name $umGroupName -ManagedBy $ManagedBy -BootstrapMember $BootstrapMember -WarningVariable ugWarnings
            foreach ($w in $ugWarnings) {
                if ([string]$w.Message -like '*already exists*') { $result.Warnings += [string]$w.Message }
            }
            if ($ugResult) {
                $result.OwnerRequested = $ugResult.OwnerRequested
                $result.OwnerAdded    = $ugResult.OwnerAdded
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
                if ($ManagedBy -and $ManagedBy -ne 'GraphAPI-Dummy-owner') {
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

            # --- Ensure EXO ServicePrincipal extension (delegated to Register-EXOServicePrincipal)
            $exoSpDisplay = "{0}_SP" -f $sp.DisplayName
            $null = Register-EXOServicePrincipal -AppId $sp.AppId -ObjectId $sp.Id -DisplayName $exoSpDisplay

            # --- Role assignments
            $rolesNormalized = foreach ($r in @($Role)) { Get-NormalizeRole $r }
            $result.RolesNormalized = @($rolesNormalized)

            foreach ($roleItem in $rolesNormalized) {
                $ShortRoleName = $shortRoleMap[$roleItem]

                $rbacNameBase = Get-SafeName -s ("{0}-{1}" -f $ShortRoleName,$sp.DisplayName) -max 63
                $result.RoleAssignmentsName += $rbacNameBase

                # --- Skip creation if a role assignment with this deterministic name already
                # exists, so re-running against an already-provisioned app is idempotent. Members
                # were already added above regardless of this check.
                $existingAssignment = Get-ManagementRoleAssignment -Identity $rbacNameBase -ErrorAction SilentlyContinue
                if ($existingAssignment) {
                    $scopedToTarget = ([string]$existingAssignment.RecipientWriteScope -in @('Group', 'CustomRecipientScope')) -and
                        ([string]$existingAssignment.CustomRecipientWriteScope -eq $umGroupName)
                    if ($scopedToTarget) {
                        $existsMsg = "Role assignment '$rbacNameBase' already exists and is scoped to '$umGroupName'; skipping creation."
                    }
                    else {
                        $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped to '$([string]$existingAssignment.CustomRecipientWriteScope)', not '$umGroupName'; leaving it as-is. Use Set-RBAC4AppEntry to re-scope it."
                    }
                    $result.Warnings += $existsMsg
                    Write-Warning -Message $existsMsg
                    $result.RoleAssignments += $existingAssignment
                    continue
                }

                if ($PSCmdlet.ShouldProcess("RBAC role assignment", "Assign '$roleItem' to App '$($sp.DisplayName)' scoped to '$umGroupName'")) {
                    $assignment = New-ManagementRoleAssignment `
                        -App $sp.Id `
                        -Role $roleItem `
                        -RecipientGroupScope $umGroupName `
                        -Name $rbacNameBase `
                        -ErrorAction Stop
                    $result.RoleAssignments += $assignment
                }
            }

            [pscustomobject]$result
            [pscustomobject]$result | Export-Clixml ('{0}/{1}_{2}.clixml' -f $env:TEMP,$rbacNameBase,(get-date -format s).Replace(':','')) -Verbose
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
