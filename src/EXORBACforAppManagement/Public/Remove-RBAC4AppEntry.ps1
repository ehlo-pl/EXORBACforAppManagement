<#
.SYNOPSIS
Safely removes the Exchange Online RBAC scoping that New-RBAC4AppEntry creates for an Entra
application.

.DESCRIPTION
Remove-RBAC4AppEntry is the teardown counterpart to New-RBAC4AppEntry. It resolves an Entra
application / service principal (by display name, AppId, or service principal object id), derives the
scoped Unified Group name the same way New-RBAC4AppEntry does ("{GroupPrefix}-{DisplayName}",
sanitized via Get-SafeName) and the management scope name ("{ManagementScopePrefix}-{DisplayName}"
or -ManagementScopeName), and removes, in order:

  1. this application's Exchange Online management role assignments bound to that management scope
     (-CustomResourceScope) or - for assignments created before 0.7.0 - directly to the scope group
     (legacy -RecipientGroupScope),
  2. the management scope itself (skipped while another identity's assignment still uses it), and
  3. for -ScopeKind Group, the scope group itself (never a MailEnabledSecurityGroup).

Before removing anything the function runs two safety checks and ABORTS (removing nothing) if either
fails:

  * Foreign role assignments - if any management role assignment bound to the management scope or
    scoped to the group resolves to a DIFFERENT identity than this service principal, the scope is
    still in use and removal is refused.
  * Real members - if the group has any member other than the bootstrap placeholder
    (-BootstrapMember, default 'GraphAPI-Dummy'), the group is still in use and removal is refused.

The Exchange Online service principal pointer ("{DisplayName}_SP") is intentionally left in place
because it may be shared by other scoping. There is no -Role parameter: the safety question is about
the group as a whole, so the teardown operates at group granularity and removes all of this app's
assignments scoped to the group or nothing at all.

The function supports -WhatIf and -Confirm through SupportsShouldProcess; under -WhatIf no removals
are performed and IsRemoved is reported as false.

.PARAMETER RegisteredAppName
Display name of the registered application or service principal. Default parameter set; must resolve
to exactly one service principal.

.PARAMETER AppId
Application (client) id of the registered application. GUID-validated.

.PARAMETER SpObjectId
Object id of the target service principal. GUID-validated.

.PARAMETER GroupPrefix
Prefix used when building the scope group name (matching New-RBAC4AppEntry). When omitted,
defaults to 'UDLRAo1P' (DistributionList), 'USRAo1P' (MailEnabledSecurityGroup), or
'Um365RAo1P' (M365Group) based on -AccessGroupType.

.PARAMETER AccessGroupName
Explicit scope group name to tear down instead of generating one from GroupPrefix and the
resolved display name. Required when -AccessGroupType is MailEnabledSecurityGroup.

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope (M365Group, DistributionList, or
MailEnabledSecurityGroup). Defaults to DistributionList (matching New-RBAC4AppEntry). A
MailEnabledSecurityGroup is on-prem/hybrid-synced and is NEVER deleted by this function - only
this application's role assignments are detached; a DistributionList is removed with
Remove-DistributionGroup.

.PARAMETER ScopeKind
Kind of management scope that was provisioned (Group default, Recipients, Tag, Filter). Only Group
has a backing scope group to tear down; the filter parameters are not needed for removal.

.PARAMETER ManagementScopeName
Explicit management scope name. Cannot be combined with -ManagementScopePrefix.

.PARAMETER ManagementScopePrefix
Prefix of the generated management scope name "{Prefix}-{DisplayName}". Default 'MSRAo1P'.

.PARAMETER BootstrapMember
Bootstrap placeholder member to ignore when deciding whether the group has real members. Defaults to
'GraphAPI-Dummy' (matching New-RBAC4AppEntry).

.EXAMPLE
Remove-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -WhatIf -Verbose

Shows the role assignments and Unified Group that would be removed for the resolved application,
without making changes.

.EXAMPLE
Remove-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555'

Removes this application's role assignments and the scoped Unified Group, but only if no foreign
assignments and no real members are present.

.OUTPUTS
PSCustomObject

A summary object with the resolved identity, the Unified Group name and whether it existed, the
assignments scoped to the group partitioned into own/foreign, the real members found, what was
removed (AssignmentsRemoved, ManagementScopeRemoved, GroupRemoved), an overall IsRemoved flag, a Reason when removal was
refused or skipped, and any Warnings/Errors.

.NOTES
Requires a connected Exchange Online session only (Get-ServicePrincipal, Get-ConnectionInformation,
Get-UnifiedGroup, Get-UnifiedGroupLinks, Get-ManagementScope, Get-ManagementRoleAssignment,
Remove-ManagementRoleAssignment, Remove-ManagementScope, Remove-UnifiedGroup). No Microsoft Graph session is needed; the
application is resolved against the Exchange Online service principal pointer already registered
via Register-EXOServicePrincipal, New-RBAC4AppEntry, or Invoke-RBAC4AppConfig. Inverse of
New-RBAC4AppEntry; the safe companion to Test-RBAC4AppEntry.
#>
function Remove-RBAC4AppEntry {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
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
        [string] $GroupPrefix = $null,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'DistributionList',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BootstrapMember = 'GraphAPI-Dummy',

        [Parameter()]
        [ValidateSet('Group', 'Recipients', 'Tag', 'Filter')]
        [string] $ScopeKind = 'Group',

        [Parameter()]
        [ValidateLength(1, 64)]
        [string] $ManagementScopeName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagementScopePrefix = 'MSRAo1P'
    )

    begin {
        $tenantid = $null
        try { $tenantid = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1 -ExpandProperty TenantId }
        catch { Write-Verbose -Message "Could not read tenant id from Get-ConnectionInformation: $($_.Exception.Message)" }
    }

    process {
        if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) {
            $GroupPrefix = switch ($AccessGroupType) {
                'DistributionList'         { 'UDLRAo1P' }
                'MailEnabledSecurityGroup' { 'USRAo1P' }
                default                    { 'Um365RAo1P' }
            }
        }

        $result = [ordered]@{
            ParameterSet        = $PSCmdlet.ParameterSetName
            IdentityInput       = $RegisteredAppName
            ResolvedDisplay     = $null
            AppId               = $null
            SpObjectId          = $null
            TenantId            = $tenantid
            ScopeKind           = $ScopeKind
            AccessGroupType     = if ($ScopeKind -eq 'Group') { $AccessGroupType } else { $null }
            ManagementScopeName    = $null
            ManagementScopeExisted = $false
            ManagementScopeRemoved = $false
            ScopeGroupName      = $null
            ScopeGroupExisted   = $false
            AssignmentsScoped   = @()
            OwnAssignments      = @()
            ForeignAssignments  = @()
            RealMembers         = @()
            AssignmentsRemoved  = @()
            GroupRemoved        = $false
            IsRemoved           = $false
            Reason              = $null
            Warnings            = @()
            Errors              = @()
        }

        try {
            if ($PSBoundParameters.ContainsKey('ManagementScopeName') -and $PSBoundParameters.ContainsKey('ManagementScopePrefix')) {
                throw "Parameters -ManagementScopeName and -ManagementScopePrefix cannot be used together."
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

            $result.ResolvedDisplay = $sp.DisplayName
            $result.AppId           = $sp.AppId
            $result.SpObjectId      = $sp.Id

            # --- Scope group name (same rule as New-RBAC4AppEntry; read cmdlet per type). Only
            # relevant for -ScopeKind Group; other kinds have no backing group.
            $umGroupName = $null
            $group = $null
            $isMesg = ($ScopeKind -eq 'Group' -and $AccessGroupType -eq 'MailEnabledSecurityGroup')
            if ($ScopeKind -eq 'Group') {
                if ($PSBoundParameters.ContainsKey('AccessGroupName')) {
                    $umGroupName = $AccessGroupName
                }
                elseif ($isMesg) {
                    throw "-AccessGroupName is required when -AccessGroupType is MailEnabledSecurityGroup."
                }
                else {
                    $umGroupName = Get-SafeName -s ("{0}-{1}" -f $GroupPrefix, $sp.DisplayName)
                }
                $result.ScopeGroupName = $umGroupName

                $group = switch ($AccessGroupType) {
                    'DistributionList'         { Get-DistributionGroup -Identity $umGroupName -ErrorAction SilentlyContinue }
                    'MailEnabledSecurityGroup' { Get-Recipient -Identity $umGroupName -ErrorAction SilentlyContinue }
                    default                    { Get-UnifiedGroup -Identity $umGroupName -ErrorAction SilentlyContinue }
                }
                $result.ScopeGroupExisted = [bool]$group
            }

            # --- Management scope (same name rule as New-RBAC4AppEntry).
            $scopeName = Get-RBAC4AppManagementScopeName -DisplayName $sp.DisplayName -Prefix $ManagementScopePrefix -Name $ManagementScopeName
            $result.ManagementScopeName = $scopeName
            $scopeObj = $null
            try { $scopeObj = Get-ManagementScope -Identity $scopeName -ErrorAction Stop | Select-Object -First 1 }
            catch { Write-Verbose -Message "Management scope '$scopeName' not found: $($_.Exception.Message)" }
            $result.ManagementScopeExisted = [bool]$scopeObj

            # --- Assignments bound to the management scope, or (legacy) directly to the scope group.
            # Client-side filter: there is no -App/-CustomResourceScope filter on the EXO cmdlet.
            $scopeStates = @{}
            $scoped = @(Get-ManagementRoleAssignment -ErrorAction SilentlyContinue) | Where-Object {
                if (-not $_) { return $false }
                $st = (Get-RBAC4AppAssignmentScopeState -Assignment $_ -ManagementScopeName $scopeName -LegacyGroupName $umGroupName).State
                $scopeStates[[string]$_.Name] = $st
                $st -in @('Target', 'LegacyGroup')
            }
            $result.AssignmentsScoped = @($scoped | ForEach-Object { [string]$_.Name })

            # --- Partition own vs foreign by assignee (same needle set as Get-RBAC4AppEntry).
            $needles = @($sp.DisplayName, ("{0}_SP" -f $sp.DisplayName), $sp.AppId, $sp.Id) | Where-Object { $_ }
            $own = @()
            $foreign = @()
            foreach ($a in $scoped) {
                $assignee = [string]$a.RoleAssigneeName
                $isOwn = $false
                foreach ($n in $needles) {
                    $escapedNeedle = [System.Management.Automation.WildcardPattern]::Escape([string]$n)
                    if ($assignee -and $assignee -like "*$escapedNeedle*") { $isOwn = $true; break }
                }
                if ($isOwn) { $own += $a } else { $foreign += $a }
            }
            $result.OwnAssignments     = @($own | ForEach-Object { [string]$_.Name })
            $result.ForeignAssignments = @($foreign | ForEach-Object { [string]$_.Name })
            $foreignOnScope = @($foreign | Where-Object { $scopeStates[[string]$_.Name] -eq 'Target' })

            # --- Real members (ignore the bootstrap placeholder).
            $realMembers = @()
            if ($group) {
                $links = if ($AccessGroupType -eq 'M365Group') {
                    @(Get-UnifiedGroupLinks -Identity $umGroupName -LinkType Members -ErrorAction SilentlyContinue)
                }
                else {
                    @(Get-DistributionGroupMember -Identity $umGroupName -ErrorAction SilentlyContinue)
                }
                foreach ($l in $links) {
                    if (-not $l) { continue }
                    $smtp = [string]$l.PrimarySmtpAddress
                    $name = [string]$l.Name
                    if (($smtp -and $smtp -eq $BootstrapMember) -or ($name -and $name -eq $BootstrapMember)) { continue }
                    $realMembers += if ($smtp) { $smtp } else { $name }
                }
            }
            $result.RealMembers = @($realMembers)

            # --- Safety gate: abort (remove nothing) when the group / scope is still in use. A
            # MailEnabledSecurityGroup is exempt: it is on-prem/hybrid-synced and never deleted, so
            # only this app's assignments (and the scope, when unused) are detached.
            if (-not $isMesg -and ($foreign.Count -gt 0 -or $realMembers.Count -gt 0)) {
                $target = if ($umGroupName) { "'$umGroupName' / management scope '$scopeName'" } else { "management scope '$scopeName'" }
                $parts = @()
                if ($foreign.Count -gt 0)     { $parts += "$($foreign.Count) foreign role assignment(s) scoped to it" }
                if ($realMembers.Count -gt 0) { $parts += "$($realMembers.Count) member(s) beyond the '$BootstrapMember' placeholder" }
                $result.Reason = "Refusing to remove $target`: it is still in use ($($parts -join '; '))."
                $result.IsRemoved = $false
                Write-Warning -Message $result.Reason
                return [pscustomobject]$result
            }

            # --- Remove this app's assignments first (EXO refuses to delete a scope still in use).
            $removedAny = $false
            foreach ($a in $own) {
                $name = [string]$a.Name
                if ($PSCmdlet.ShouldProcess($name, 'Remove-ManagementRoleAssignment')) {
                    try {
                        Remove-ManagementRoleAssignment -Identity $name -Confirm:$false -ErrorAction Stop
                        $result.AssignmentsRemoved += $name
                        $removedAny = $true
                    }
                    catch {
                        $result.Errors += "Failed to remove role assignment '$name': $($_.Exception.Message)"
                    }
                }
            }

            # --- Then the management scope, unless another identity's assignment still uses it.
            if ($scopeObj) {
                if ($foreignOnScope.Count -gt 0) {
                    $result.Warnings += "Management scope '$scopeName' is still used by $($foreignOnScope.Count) foreign role assignment(s) and was left in place."
                }
                elseif ($result.Errors.Count -gt 0) {
                    $result.Warnings += "Management scope '$scopeName' was left in place because removing role assignments failed."
                }
                elseif ($PSCmdlet.ShouldProcess($scopeName, 'Remove-ManagementScope')) {
                    try {
                        Remove-ManagementScope -Identity $scopeName -Confirm:$false -ErrorAction Stop
                        $result.ManagementScopeRemoved = $true
                        $removedAny = $true
                    }
                    catch {
                        $result.Errors += "Failed to remove management scope '$scopeName': $($_.Exception.Message)"
                    }
                }
            }

            # --- Finally the scope group (Group kind only; a MailEnabledSecurityGroup is never deleted).
            if ($isMesg) {
                $result.Reason = "MailEnabledSecurityGroup '$umGroupName' is on-prem/hybrid-synced and was left in place; only this application's role assignments and management scope were detached."
                $result.IsRemoved = ($result.Errors.Count -eq 0) -and $removedAny
                if (-not $result.IsRemoved -and $WhatIfPreference) {
                    $result.Reason = 'WhatIf: no changes were made.'
                }
                return [pscustomobject]$result
            }

            if ($ScopeKind -eq 'Group') {
                $groupRemoveAction = if ($AccessGroupType -eq 'DistributionList') { 'Remove-DistributionGroup' } else { 'Remove-UnifiedGroup' }
                if (-not $group) {
                    $result.Warnings += "$AccessGroupType '$umGroupName' did not exist; only role assignments and the management scope (if any) were processed."
                }
                elseif ($PSCmdlet.ShouldProcess($umGroupName, $groupRemoveAction)) {
                    try {
                        if ($AccessGroupType -eq 'DistributionList') {
                            Remove-DistributionGroup -Identity $umGroupName -Confirm:$false -ErrorAction Stop
                        }
                        else {
                            Remove-UnifiedGroup -Identity $umGroupName -Confirm:$false -ErrorAction Stop
                        }
                        $result.GroupRemoved = $true
                        $removedAny = $true
                    }
                    catch {
                        $result.Errors += "Failed to remove $AccessGroupType '$umGroupName': $($_.Exception.Message)"
                    }
                }
            }

            # IsRemoved is true only when the group and management scope are gone (or never
            # existed / not applicable) and no errors occurred.
            $result.IsRemoved = ($result.Errors.Count -eq 0) -and
                                ($result.GroupRemoved -or -not $group) -and
                                ($result.ManagementScopeRemoved -or -not $scopeObj) -and
                                $removedAny
            if (-not $result.IsRemoved -and -not $result.Reason -and $WhatIfPreference) {
                $result.Reason = 'WhatIf: no changes were made.'
            }

            [pscustomobject]$result
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
