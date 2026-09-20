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
  2. the scoped Unified Group "{GroupPrefix}-{DisplayName}" (sanitized via the same Get-SafeName
     rule) exists,
  3. the Exchange Online service principal pointer named exactly "{DisplayName}_SP" - by that
     deterministic name, or by AppId - exists (ExoServicePrincipalExists; distinct from #1, which
     resolves the application by whichever identity the caller supplied), and
  4. one Exchange Online management role assignment exists per requested role, named the same way
     New-RBAC4AppEntry names them ("{ShortRoleToken}-{DisplayName}") and bound to the expected
     role.

When -Members is supplied, the requested recipients are also verified against the Unified Group's
membership. The function is read-only: it makes no changes and does not support -WhatIf.

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
Optional recipients expected to be members of the Unified Group scope. When supplied, each is
resolved through Get-Recipient and checked against the group's membership. Omit to skip the
membership check.

.PARAMETER GroupPrefix
Prefix used when building the Unified Group name. Defaults to 'Um365RAo1' (matching
New-RBAC4AppEntry).

.PARAMETER AccessGroupName
Explicit scope group name to check instead of generating one from GroupPrefix and the
resolved display name. Required when -AccessGroupType is MailEnabledSecurityGroup.

.PARAMETER AccessGroupType
Kind of group that backs the RBAC scope (M365Group, DistributionList, or
MailEnabledSecurityGroup). Defaults to M365Group. Controls which cmdlets are used to read
the group and its membership.

.EXAMPLE
Test-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App'

Validates the default Application Mail.Send setup for the resolved application and returns a summary
with an IsValid flag.

.EXAMPLE
Test-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' -Role 'Mail.Send','Calendars.Read' -Members 'shared@contoso.com'

Checks the service principal, Unified Group, Exchange Online service principal, both role
assignments, and that shared@contoso.com is a group member.

.EXAMPLE
New-RBAC4AppEntry -RegisteredAppName 'Contoso' -WhatIf; Test-RBAC4AppEntry -RegisteredAppName 'Contoso'

Reports which components are still missing before/after a run.

.OUTPUTS
PSCustomObject

A summary object with the resolved identity, per-component existence flags
(ServicePrincipalExists, ScopeGroupExists, ExoServicePrincipalExists), the expected/found/missing
role assignments, optional membership results, an overall IsValid flag, a Missing list, and any
Warnings/Errors.

.NOTES
Requires a connected Exchange Online session only (Get-ServicePrincipal, Get-ConnectionInformation,
Get-UnifiedGroup, Get-ManagementRoleAssignment, and, when -Members is supplied, Get-Recipient and
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
        [ValidateNotNullOrEmpty()]
        [string] $GroupPrefix = 'Um365RAo1',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'M365Group'
    )

    begin {
        $shortRoleMap = Get-AppRoleMap

        $tenantid = $null
        try { $tenantid = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1 -ExpandProperty TenantId }
        catch { Write-Verbose -Message "Could not read tenant id from Get-ConnectionInformation: $($_.Exception.Message)" }
    }

    process {
        $result = [ordered]@{
            ParameterSet            = $PSCmdlet.ParameterSetName
            IdentityInput           = $RegisteredAppName
            ResolvedDisplay         = $null
            AppId                   = $null
            SpObjectId              = $null
            TenantId                = $tenantid
            AccessGroupType         = $AccessGroupType
            ServicePrincipalExists  = $false
            ScopeGroupName          = $null
            ScopeGroupExists        = $false
            ExoServicePrincipalName = $null
            ExoServicePrincipalExists = $false
            RolesExpected           = @()
            RoleAssignmentsExpected = @()
            RoleAssignmentsFound    = @()
            RoleAssignmentsMissing  = @()
            MembersExpected         = @()
            MembersPresent          = @()
            MembersMissing          = @()
            IsValid                 = $false
            Missing                 = @()
            Warnings                = @()
            Errors                  = @()
        }

        try {
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
            if ($group) {
                $result.ScopeGroupExists = $true
            }
            else {
                $result.Missing += "$AccessGroupType '$umGroupName'"
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

            # --- Role assignment existence, by the deterministic name New-RBAC4AppEntry builds.
            $rolesNormalized = foreach ($r in @($Role)) { Get-NormalizeRole $r }
            $result.RolesExpected = @($rolesNormalized)

            foreach ($roleItem in $rolesNormalized) {
                $shortRoleName = $shortRoleMap[$roleItem]
                if (-not $shortRoleName) {
                    $result.Warnings += "Role '$roleItem' is not a recognized application role; skipping its assignment check."
                    continue
                }

                $expectedName = Get-SafeName -s ("{0}-{1}" -f $shortRoleName, $sp.DisplayName) -max 63
                $result.RoleAssignmentsExpected += $expectedName

                $assignment = Get-ManagementRoleAssignment -Identity $expectedName -ErrorAction SilentlyContinue
                if ($assignment -and ([string]$assignment.Role -eq $roleItem)) {
                    $result.RoleAssignmentsFound += $expectedName
                }
                else {
                    $result.RoleAssignmentsMissing += $expectedName
                    $result.Missing += "Role assignment '$expectedName' ($roleItem)"
                }
            }

            # --- Optional membership check.
            if ($PSBoundParameters.ContainsKey('Members')) {
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
                              $result.ScopeGroupExists -and
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
