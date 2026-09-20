<#
.SYNOPSIS
Creates or updates Exchange Online RBAC scoping for an Entra application service principal.

.DESCRIPTION
New-RBAC4AppEntry resolves an Entra service principal by display name, AppId, or
service principal object id, creates the scoped Unified Group when needed, adds
requested members, ensures the Exchange Online service principal exists, and creates
Exchange Online RBAC role assignments for the application.

Unified Group creation/configuration is delegated to New-RBAC4AppUnifiedGroup and the
Exchange Online service principal step to Register-EXOServicePrincipal. Every creation step is
idempotent: the scope group, the EXO service principal, and each role assignment are only created
if a matching one does not already exist, so re-running against an already-provisioned application
is safe - a role assignment that already exists and is scoped to the same group is left alone (a
warning notes it was skipped); requested members are still added to the group regardless.

The function supports -WhatIf and -Confirm through SupportsShouldProcess.

.PARAMETER RegisteredAppName
Display name of the registered application or service principal. This is the default
parameter set and must resolve to exactly one service principal.

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

.OUTPUTS
PSCustomObject

Returns a summary object with resolved identity, Unified Group name, normalized roles,
assignment names, warnings, and errors.

.NOTES
Requires Microsoft Graph and Exchange Online cmdlets used by Get-MgServicePrincipal,
New-ServicePrincipal, Get-UnifiedGroup, Set-UnifiedGroup, Add-UnifiedGroupLinks,
Get-UnifiedGroupLinks, Get-DistributionGroupMember, Get-ManagementRoleAssignment, and
New-ManagementRoleAssignment.
#>
function New-RBAC4AppEntry {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
    param(
        # Default: resolve by displayName (can be non-unique; will error if ambiguous)
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [Alias('DisplayName','Name')]
        [ValidateNotNullOrEmpty()]
        [string] $RegisteredAppName,

        # Alternative: resolve by AppId (GUID)
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByAppId')]
        [Alias('ClientId','ApplicationId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        # Alternative: resolve by Service Principal ObjectId (GUID)
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'BySpObjectId')]
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

        $tenantid = Get-MgContext | Select-Object -ExpandProperty TenantId
    }

    process {
        if ($PSBoundParameters.ContainsKey('AccessGroupName') -and $PSBoundParameters.ContainsKey('GroupPrefix')) {
            throw "Parameters -AccessGroupName and -GroupPrefix cannot be used together."
        }

        $result = [ordered]@{
            ParameterSet      = $PSCmdlet.ParameterSetName
            IdentityInput     = $RegisteredAppName
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
            # --- Resolve service principal depending on parameter set
            $sp = $null
            switch ($PSCmdlet.ParameterSetName) {
                'BySpObjectId' {
                    $sp = Get-MgServicePrincipal -ServicePrincipalId $SpObjectId -ErrorAction Stop
                }

                'ByAppId' {
                    $filter = "appId eq `'$AppId`'"
                    $matchesRes = @(Get-MgServicePrincipal -Filter $filter -ErrorAction Stop)
                    if ($matchesRes.Count -eq 0) { throw "No service principal found for AppId '$AppId'." }
                    if ($matchesRes.Count -gt 1) { throw "Unexpected: multiple service principals for AppId '$AppId'." }
                    $sp = $matchesRes[0]
                }

                'ByName' {
                    $filter = "displayName eq `'$RegisteredAppName`'"
                    $matchesRes = @(Get-MgServicePrincipal -Filter $filter -ErrorAction Stop)
                    if ($matchesRes.Count -eq 0) { throw "No service principal found for displayName '$RegisteredAppName'." }
                    if ($matchesRes.Count -gt 1) {
                        $names = ($matchesRes | Select-Object -First 10 -ExpandProperty Id) -join ', '
                        throw "Ambiguous displayName '$RegisteredAppName' matched $($matchesRes.Count) service principals. Re-run with -AppId or -SpObjectId. Example SP objectIds: $names"
                    }
                    $sp = $matchesRes[0]
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
                    $connectionInfo = Get-MgContext -ErrorAction Stop
                    $currentUserUpn = $connectionInfo.Account
                }
                catch {
                    $result.Warnings += "Could not retrieve current connection user via get-mgContext; connection user filtering will be skipped. Error: $($_.Exception.Message)"
                    Write-Warning -Message "Could not retrieve current connection user via get-mgContext; connection user filtering will be skipped."
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
