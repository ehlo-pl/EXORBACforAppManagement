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
  4. the management scope "{ManagementScopePrefix}-{DisplayName}" (or -ManagementScopeName) exists
     and its RecipientRestrictionFilter matches the one New-RBAC4AppEntry would build for the
     selected -ScopeKind, and
  5. one Exchange Online management role assignment exists per requested role, named the same way
     New-RBAC4AppEntry names them ("{ShortRoleToken}-{DisplayName}"), bound to the expected role
     and to that management scope (-CustomResourceScope). Assignments still scoped directly to the
     group (legacy -RecipientGroupScope) are reported in RoleAssignmentsLegacyScoped and count as
     missing; run Set-RBAC4AppEntry to migrate them.

When -Members is supplied (ScopeKind Group only), the requested recipients are also verified
against the scope group's membership. The function is read-only: it makes no changes and does not support -WhatIf.

The defaults for -Role and -GroupPrefix mirror New-RBAC4AppEntry, so a plain
"Test-RBAC4AppEntry -RegisteredAppName <app>" validates the default creation.

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
defaults to 'UDLRAo1P' (DistributionList), 'USRAo1P' (MailEnabledSecurityGroup), or
'Um365RAo1P' (M365Group) based on -AccessGroupType.

.PARAMETER AccessGroupName
Explicit scope group name to check instead of generating one from GroupPrefix and the
resolved display name. Required when -AccessGroupType is MailEnabledSecurityGroup.

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope (M365Group, DistributionList, or
MailEnabledSecurityGroup). Defaults to DistributionList (matching New-RBAC4AppEntry). Controls
which cmdlets are used to read the group and its membership.

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
Warnings/Errors.

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
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'DistributionList',

        [Parameter()]
        [ValidateSet('Group', 'Recipients', 'Tag', 'Filter')]
        [string] $ScopeKind = 'Group',

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
            AccessGroupType         = if ($ScopeKind -eq 'Group') { $AccessGroupType } else { $null }
            ServicePrincipalExists  = $false
            ScopeGroupName          = $null
            ScopeGroupExists        = $false
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
            MembersExpected         = @()
            MembersPresent          = @()
            MembersMissing          = @()
            IsValid                 = $false
            Missing                 = @()
            Warnings                = @()
            Errors                  = @()
        }

        try {
            if ($PSBoundParameters.ContainsKey('ManagementScopeName') -and $PSBoundParameters.ContainsKey('ManagementScopePrefix')) {
                throw "Parameters -ManagementScopeName and -ManagementScopePrefix cannot be used together."
            }
            if ($ScopeKind -eq 'Recipients' -and -not $ScopeRecipients) {
                throw "-ScopeRecipients is required when -ScopeKind is Recipients."
            }
            if ($ScopeKind -eq 'Filter' -and -not $ScopeFilter) {
                throw "-ScopeFilter is required when -ScopeKind is Filter."
            }
            foreach ($ignoredMsg in @(Get-RBAC4AppScopeKindWarning -ScopeKind $ScopeKind -BoundParameters $PSBoundParameters)) {
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
            $result.SpObjectId             = $sp.Id

            # --- Scope group existence (same name rule as New-RBAC4AppEntry; read cmdlet per type).
            # Only relevant for -ScopeKind Group; other kinds have no backing group.
            $umGroupName = $null
            $group = $null
            if ($ScopeKind -eq 'Group') {
            #REINDENT-START
            if ($PSBoundParameters.ContainsKey('AccessGroupName')) {
                $umGroupName = $AccessGroupName
            }
            elseif ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                throw "-AccessGroupName is required when -AccessGroupType is MailEnabledSecurityGroup."
            }
            else {
                $umGroupName = Get-RBAC4AppScopeGroupName -Prefix $GroupPrefix -DisplayName $sp.DisplayName
            }
            $result.ScopeGroupName = $umGroupName
            $group = switch ($AccessGroupType) {
                'DistributionList'         { Get-DistributionGroup -Identity $umGroupName -ErrorAction SilentlyContinue }
                'MailEnabledSecurityGroup' { Get-Recipient -Identity $umGroupName -ErrorAction SilentlyContinue }
                default                    { Get-UnifiedGroup -Identity $umGroupName -ErrorAction SilentlyContinue }
            }
            if ($group) {
                $result.ScopeGroupExists = $true
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
            $scopeName = Get-RBAC4AppManagementScopeName -DisplayName $sp.DisplayName -Prefix $ManagementScopePrefix -Name $ManagementScopeName
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

            # --- Role assignment existence, by the deterministic name New-RBAC4AppEntry builds.
            $rolesNormalized = foreach ($r in @($Role)) { ConvertTo-RBAC4AppRoleName -Role $r }
            $result.RolesExpected = @($rolesNormalized)
            $assigneeNeedles = @($sp.DisplayName, ("{0}_SP" -f $sp.DisplayName), $sp.AppId, $sp.Id) | Where-Object { $_ }

            foreach ($roleItem in $rolesNormalized) {
                $shortRoleName = $shortRoleMap[$roleItem]
                if (-not $shortRoleName) {
                    $result.Warnings += "Role '$roleItem' is not a recognized application role; skipping its assignment check."
                    continue
                }

                $expectedName = Get-RBAC4AppRoleAssignmentName -ShortRoleName $shortRoleName -DisplayName $sp.DisplayName
                $result.RoleAssignmentsExpected += $expectedName

                $assignment = Get-ManagementRoleAssignment -Identity $expectedName -ErrorAction SilentlyContinue
                $assignmentMatches = $false
                $assignmentLegacy = $false
                foreach ($candidate in @($assignment | Where-Object { $_ })) {
                    $assignee = [string]$candidate.RoleAssigneeName
                    $assigneeMatches = $false
                    foreach ($n in $assigneeNeedles) {
                        if ($assignee -and $assignee -like "*$n*") { $assigneeMatches = $true; break }
                    }

                    if (([string]$candidate.Role -ne $roleItem) -or -not $assigneeMatches) { continue }
                    $state = (Get-RBAC4AppAssignmentScopeState -Assignment $candidate -ManagementScopeName $scopeName -LegacyGroupName $umGroupName).State
                    if ($state -eq 'Target') {
                        $assignmentMatches = $true
                        break
                    }
                    if ($state -eq 'LegacyGroup') { $assignmentLegacy = $true }
                }

                if ($assignmentMatches) {
                    $result.RoleAssignmentsFound += $expectedName
                }
                elseif ($assignmentLegacy) {
                    $result.RoleAssignmentsMissing += $expectedName
                    $result.RoleAssignmentsLegacyScoped += $expectedName
                    $result.Missing += "Role assignment '$expectedName' ($roleItem) is scoped directly to group '$umGroupName' (legacy -RecipientGroupScope); run Set-RBAC4AppEntry to migrate it onto management scope '$scopeName'"
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
                              $result.ManagementScopeExists -and
                              $result.ManagementScopeFilterMatches -and
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
