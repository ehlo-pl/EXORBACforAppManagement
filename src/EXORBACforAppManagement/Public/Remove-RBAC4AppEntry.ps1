<#
.SYNOPSIS
Safely removes the Exchange Online RBAC scoping that New-RBAC4AppEntry creates for an Entra
application.

.DESCRIPTION
Remove-RBAC4AppEntry is the teardown counterpart to New-RBAC4AppEntry. It resolves an Entra
application / service principal (by display name, AppId, or service principal object id), derives the
scoped Unified Group name the same way New-RBAC4AppEntry does ("{GroupPrefix}-{DisplayName}",
sanitized via Get-SafeName), and removes:

  1. the Exchange Online management role assignments scoped to that group that belong to this
     application, and
  2. the scoped Unified Group itself.

Before removing anything the function runs two safety checks and ABORTS (removing nothing) if either
fails:

  * Foreign role assignments - if any management role assignment scoped to the group resolves to a
    DIFFERENT identity than this service principal, the group is still in use and removal is refused.
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
Prefix used when building the Unified Group name. Defaults to 'Um365RAo1' (matching
New-RBAC4AppEntry).

.PARAMETER AccessGroupName
Explicit scope group name to tear down instead of generating one from GroupPrefix and the
resolved display name. Required when -AccessGroupType is MailEnabledSecurityGroup.

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope (M365Group, DistributionList, or
MailEnabledSecurityGroup). Defaults to M365Group. A MailEnabledSecurityGroup is
on-prem/hybrid-synced and is NEVER deleted by this function - only this application's role
assignments are detached; a DistributionList is removed with Remove-DistributionGroup.

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
removed (AssignmentsRemoved, GroupRemoved), an overall IsRemoved flag, a Reason when removal was
refused or skipped, and any Warnings/Errors.

.NOTES
Requires a connected Microsoft Graph session (Get-MgServicePrincipal, Get-MgContext) and a connected
Exchange Online session (Get-UnifiedGroup, Get-UnifiedGroupLinks, Get-ManagementRoleAssignment,
Remove-ManagementRoleAssignment, Remove-UnifiedGroup). Inverse of New-RBAC4AppEntry; the safe
companion to Test-RBAC4AppEntry.
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
        [ValidateNotNullOrEmpty()]
        [string] $GroupPrefix = 'Um365RAo1',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'M365Group',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BootstrapMember = 'GraphAPI-Dummy'
    )

    begin {
        $tenantid = $null
        try { $tenantid = Get-MgContext | Select-Object -ExpandProperty TenantId }
        catch { Write-Verbose -Message "Could not read tenant id from Get-MgContext: $($_.Exception.Message)" }
    }

    process {
        $result = [ordered]@{
            ParameterSet        = $PSCmdlet.ParameterSetName
            IdentityInput       = $RegisteredAppName
            ResolvedDisplay     = $null
            AppId               = $null
            SpObjectId          = $null
            TenantId            = $tenantid
            AccessGroupType     = $AccessGroupType
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
            # --- Resolve the service principal depending on parameter set.
            $sp = $null
            switch ($PSCmdlet.ParameterSetName) {
                'BySpObjectId' {
                    $result.IdentityInput = $SpObjectId
                    $sp = Get-MgServicePrincipal -ServicePrincipalId $SpObjectId -ErrorAction Stop
                }
                'ByAppId' {
                    $result.IdentityInput = $AppId
                    $matchesRes = @(Get-MgServicePrincipal -Filter "appId eq `'$AppId`'" -ErrorAction Stop)
                    if ($matchesRes.Count -eq 0) { throw "No service principal found for AppId '$AppId'." }
                    if ($matchesRes.Count -gt 1) { throw "Unexpected: multiple service principals for AppId '$AppId'." }
                    $sp = $matchesRes[0]
                }
                'ByName' {
                    $matchesRes = @(Get-MgServicePrincipal -Filter "displayName eq `'$RegisteredAppName`'" -ErrorAction Stop)
                    if ($matchesRes.Count -eq 0) { throw "No service principal found for displayName '$RegisteredAppName'." }
                    if ($matchesRes.Count -gt 1) {
                        $ids = ($matchesRes | Select-Object -First 10 -ExpandProperty Id) -join ', '
                        throw "Ambiguous displayName '$RegisteredAppName' matched $($matchesRes.Count) service principals. Re-run with -AppId or -SpObjectId. Example SP objectIds: $ids"
                    }
                    $sp = $matchesRes[0]
                }
            }

            $result.ResolvedDisplay = $sp.DisplayName
            $result.AppId           = $sp.AppId
            $result.SpObjectId      = $sp.Id

            # --- Scope group name (same rule as New-RBAC4AppEntry; read cmdlet per type).
            if ($PSBoundParameters.ContainsKey('AccessGroupName')) {
                $umGroupName = $AccessGroupName
            }
            elseif ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
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

            # --- Assignments scoped to the group (client-side filter: no -App on the EXO cmdlet).
            $scoped = @(Get-ManagementRoleAssignment -ErrorAction SilentlyContinue) | Where-Object {
                $_ -and
                ([string]$_.RecipientWriteScope -in @('Group','CustomRecipientScope')) -and
                ([string]$_.CustomRecipientWriteScope -eq $umGroupName)
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
                    if ($assignee -and $assignee -like "*$n*") { $isOwn = $true; break }
                }
                if ($isOwn) { $own += $a } else { $foreign += $a }
            }
            $result.OwnAssignments     = @($own | ForEach-Object { [string]$_.Name })
            $result.ForeignAssignments = @($foreign | ForEach-Object { [string]$_.Name })

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

            # --- MailEnabledSecurityGroup: never delete the group (it is on-prem/hybrid-synced and
            # mastered on-premises). Detach only this app's own role assignments and leave the group
            # in place; the foreign-assignment / real-member safety gate does not apply because no
            # group deletion is attempted.
            if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
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
                $result.Reason = "MailEnabledSecurityGroup '$umGroupName' is on-prem/hybrid-synced and was left in place; only this application's role assignments were detached."
                $result.IsRemoved = ($result.Errors.Count -eq 0) -and $removedAny
                if (-not $result.IsRemoved -and $WhatIfPreference) {
                    $result.Reason = 'WhatIf: no changes were made.'
                }
                return [pscustomobject]$result
            }

            # --- Safety gate: abort (remove nothing) when the group is still in use.
            if ($foreign.Count -gt 0 -or $realMembers.Count -gt 0) {
                $parts = @()
                if ($foreign.Count -gt 0)     { $parts += "$($foreign.Count) foreign role assignment(s) scoped to the group" }
                if ($realMembers.Count -gt 0) { $parts += "$($realMembers.Count) member(s) beyond the '$BootstrapMember' placeholder" }
                $result.Reason = "Refusing to remove '$umGroupName': it is still in use ($($parts -join '; '))."
                $result.IsRemoved = $false
                Write-Warning -Message $result.Reason
                return [pscustomobject]$result
            }

            # --- Safe path: remove this app's assignments, then the group (remove cmdlet per type).
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

            $groupRemoveAction = if ($AccessGroupType -eq 'DistributionList') { 'Remove-DistributionGroup' } else { 'Remove-UnifiedGroup' }
            if (-not $group) {
                $result.Warnings += "$AccessGroupType '$umGroupName' did not exist; only role assignments (if any) were processed."
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

            # IsRemoved is true only when the group is gone (or never existed) and no errors occurred.
            $result.IsRemoved = ($result.Errors.Count -eq 0) -and
                                ($result.GroupRemoved -or -not $group) -and
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
