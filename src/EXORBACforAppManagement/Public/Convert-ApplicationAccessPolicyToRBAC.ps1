<#
.SYNOPSIS
Migrates legacy Exchange Online Application Access Policies to RBAC for Applications.

.DESCRIPTION
Convert-ApplicationAccessPolicyToRBAC reads existing Application Access Policy entries
(via Get-ApplicationAccessPolicy) and recreates the equivalent access as RBAC for
Applications assignments by delegating to New-RBAC4AppEntry.

For each RestrictAccess policy it resolves the Entra service principal, derives the
Exchange Online application roles from the app's granted Microsoft Graph application
permissions (filtered to the set that Application Access Policies supported and mapped to
their App RBAC role names via the private Get-LegacyScopeRoleMap), copies the members of
the original policy scope group, and calls New-RBAC4AppEntry to create a new scoped
Unified Group and the matching role assignments. DenyAccess policies have no additive RBAC
equivalent and are skipped with a warning.

The function supports -WhatIf and -Confirm through SupportsShouldProcess; -WhatIf
propagates into the delegated New-RBAC4AppEntry call.

.PARAMETER AppId
Application (client) id. When supplied, only Application Access Policies for that app are
converted. When omitted, all Application Access Policies are processed.

.PARAMETER Policy
Application Access Policy object(s) to convert, as emitted by Get-ApplicationAccessPolicy.
Accepts pipeline input so 'Get-ApplicationAccessPolicy | Convert-ApplicationAccessPolicyToRBAC'
works.

.PARAMETER Role
Exchange Online application roles to assign instead of the auto-derived set. Short names
such as Mail.Send are normalized to Application Mail.Send. When supplied, role derivation
from the app's Graph permissions is skipped.

.PARAMETER ManagedBy
Recipient that will be assigned as the new Unified Group owner. Passed through to
New-RBAC4AppEntry.

.PARAMETER GroupPrefix
Prefix used when building the new Unified Group name. Passed through to New-RBAC4AppEntry.

.PARAMETER AccessGroupType
Kind of group to create for the new RBAC scope. Passed through to New-RBAC4AppEntry
(M365Group or DistributionList). Defaults to M365Group. MailEnabledSecurityGroup is not
offered here: conversion mints a new scope group per policy, whereas a MailEnabledSecurityGroup
references a single pre-existing on-prem/hybrid-synced group by name.

.EXAMPLE
Convert-ApplicationAccessPolicyToRBAC -WhatIf -Verbose

Shows the planned conversion for every Application Access Policy without making changes.

.EXAMPLE
Get-ApplicationAccessPolicy | Convert-ApplicationAccessPolicyToRBAC

Converts every Application Access Policy piped in from Get-ApplicationAccessPolicy.

.EXAMPLE
Convert-ApplicationAccessPolicyToRBAC -AppId '11111111-2222-3333-4444-555555555555' -Role 'Mail.Send'

Converts the policies for one app, assigning the explicit Application Mail.Send role
instead of deriving roles from the app's Graph permission grants.

.OUTPUTS
PSCustomObject

Returns one summary object per processed policy with the resolved identity, access right,
scope group, derived roles, skipped permissions, copied members, the New-RBAC4AppEntry
result, warnings, and errors.

.NOTES
Requires connected Microsoft Graph (Get-MgServicePrincipal,
Get-MgServicePrincipalAppRoleAssignment) and Exchange Online
(Get-ApplicationAccessPolicy, plus the cmdlets used by New-RBAC4AppEntry) sessions.
#>
function Convert-ApplicationAccessPolicyToRBAC {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'All')]
    param(
        [Parameter(ParameterSetName = 'ByAppId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [Alias('ClientId','ApplicationId')]
        [string] $AppId,

        [Parameter(ValueFromPipeline, ParameterSetName = 'ByPolicy')]
        [ValidateNotNull()]
        [object[]] $Policy,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagedBy = 'GraphAPI-Dummy-owner',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $GroupPrefix = 'Um365RAo1',

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList')]
        [string] $AccessGroupType = 'M365Group'
    )

    begin {
        $legacyRoleMap = Get-LegacyScopeRoleMap
        # Cache resource service principals (e.g. Microsoft Graph) by ResourceId so the
        # AppRoleId -> permission value lookup only fetches each resource SP once.
        $resourceSpCache = @{}

        # Collect piped policies so non-pipeline filtering still works in end{}.
        $pipedPolicies = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($Policy) {
            foreach ($p in $Policy) { $pipedPolicies.Add($p) }
        }
    }

    end {
        # --- Source the policies to convert
        $policies =
            if ($pipedPolicies.Count -gt 0) {
                $pipedPolicies
            }
            else {
                try {
                    if ($PSBoundParameters.ContainsKey('AppId')) {
                        @(Get-ApplicationAccessPolicy -AppId $AppId -ErrorAction Stop)
                    }
                    else {
                        @(Get-ApplicationAccessPolicy -ErrorAction Stop)
                    }
                }
                catch {
                    Write-Error -Message ("Failed to read Application Access Policies: {0}" -f $_.Exception.Message)
                    return
                }
            }

        if (-not $policies -or @($policies).Count -eq 0) {
            Write-Verbose -Message 'No Application Access Policies found to convert.'
            return
        }

        foreach ($pol in $policies) {
            $polAppId = $pol.AppId
            $result = [ordered]@{
                AppId              = $polAppId
                ResolvedDisplay    = $null
                AccessRight        = $pol.AccessRight
                ScopeGroup         = $pol.ScopeName
                DerivedRoles       = @()
                SkippedPermissions = @()
                MembersCopied      = @()
                RBACResult         = $null
                Warnings           = @()
                Errors             = @()
            }

            try {
                # --- Only RestrictAccess policies map to additive RBAC grants
                if ($pol.AccessRight -and $pol.AccessRight -ne 'RestrictAccess') {
                    $skipMsg = "Policy AccessRight '$($pol.AccessRight)' for AppId '$polAppId' has no additive RBAC equivalent and was skipped."
                    $result.Warnings += $skipMsg
                    Write-Warning -Message $skipMsg
                    [pscustomobject]$result
                    continue
                }

                # --- Resolve the service principal from the policy AppId
                $filter = "appId eq `'$polAppId`'"
                $matchesRes = @(Get-MgServicePrincipal -Filter $filter -ErrorAction Stop)
                if ($matchesRes.Count -eq 0) { throw "No service principal found for AppId '$polAppId'." }
                if ($matchesRes.Count -gt 1) { throw "Unexpected: multiple service principals for AppId '$polAppId'." }
                $sp = $matchesRes[0]
                $result.ResolvedDisplay = $sp.DisplayName

                # --- Determine roles: explicit -Role override, else derive from grants
                $rolesNormalized = @()
                if ($PSBoundParameters.ContainsKey('Role')) {
                    $rolesNormalized = @($Role | ForEach-Object { Get-NormalizeRole $_ } | Select-Object -Unique)
                }
                else {
                    $grants = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction Stop)
                    foreach ($grant in $grants) {
                        $permValue = Resolve-AppRolePermissionValue -Grant $grant -Cache $resourceSpCache
                        if (-not $permValue) {
                            $result.SkippedPermissions += "AppRoleId $($grant.AppRoleId) (could not resolve permission name)"
                            continue
                        }
                        if ($legacyRoleMap.Contains($permValue)) {
                            $rolesNormalized += $legacyRoleMap[$permValue]
                        }
                        else {
                            $result.SkippedPermissions += $permValue
                        }
                    }
                    $rolesNormalized = @($rolesNormalized | Select-Object -Unique)
                }

                $result.DerivedRoles = @($rolesNormalized)

                if (@($rolesNormalized).Count -eq 0) {
                    $noRoleMsg = "No convertible Application Access Policy permissions found for AppId '$polAppId'; nothing to assign."
                    $result.Warnings += $noRoleMsg
                    Write-Warning -Message $noRoleMsg
                    [pscustomobject]$result
                    continue
                }

                # --- Collect members of the original scope group
                $members = @()
                if ($pol.ScopeName) {
                    try {
                        $groupMembers = @(Get-DistributionGroupMember -Identity $pol.ScopeName -ErrorAction Stop)
                        $members = @($groupMembers | ForEach-Object { [string]$_.PrimarySmtpAddress } | Where-Object { $_ })
                    }
                    catch {
                        $memberWarn = "Could not read members of scope group '$($pol.ScopeName)': $($_.Exception.Message)"
                        $result.Warnings += $memberWarn
                        Write-Warning -Message $memberWarn
                    }
                }
                $result.MembersCopied = @($members)

                # --- Delegate to New-RBAC4AppEntry (-WhatIf propagates)
                if ($PSCmdlet.ShouldProcess(
                        "AppId $polAppId ($($sp.DisplayName))",
                        "Convert Application Access Policy to RBAC roles: $($rolesNormalized -join ', ')")) {

                    # AppId, SpObjectId, and RegisteredAppName (as DisplayName) are all passed
                    # through: New-RBAC4AppEntry resolves the application against Exchange
                    # Online's own service principal pointer and no longer touches Microsoft
                    # Graph itself, so for an app that has never been registered in Exchange
                    # Online it needs all three identifiers - which Convert-ApplicationAccessPolicyToRBAC
                    # already has from its own Graph-based resolution above - to bootstrap it.
                    $rbacParams = @{
                        AppId              = $polAppId
                        SpObjectId         = $sp.Id
                        RegisteredAppName  = $sp.DisplayName
                        Role               = $rolesNormalized
                        ManagedBy          = $ManagedBy
                        GroupPrefix        = $GroupPrefix
                        AccessGroupType    = $AccessGroupType
                        ErrorAction        = 'Stop'
                    }
                    if ($members.Count -gt 0) { $rbacParams['Members'] = $members }

                    $result.RBACResult = New-RBAC4AppEntry @rbacParams
                    foreach ($w in @($result.RBACResult.Warnings)) { $result.Warnings += $w }
                    foreach ($e in @($result.RBACResult.Errors))   { $result.Errors   += $e }
                }

                [pscustomobject]$result
            }
            catch {
                $result.Errors += $_.Exception.Message
                [pscustomobject]$result
            }
        }
    }
}
