<#
.SYNOPSIS
Generates RBAC configuration files from legacy Exchange Online Application Access Policies.

.DESCRIPTION
Convert-ApplicationAccessPolicyToRBAC reads existing Application Access Policy entries
(via Get-ApplicationAccessPolicy) and writes schema 4.0 configuration files, like
New-RBAC4AppConfig, for later provisioning with Invoke-RBAC4AppConfig.

For each RestrictAccess policy it resolves the Entra service principal, derives the
Exchange Online application roles from the app's granted Microsoft Graph application
permissions (filtered to the set that Application Access Policies supported and mapped to
their App RBAC role names via the private Get-LegacyScopeRoleMap), copies the members of
the original policy scope group, and records the group settings and roles in YAML or JSON.
No Exchange Online objects are created or changed. DenyAccess policies have no additive RBAC equivalent and are
skipped with a warning.

The function supports -WhatIf and -Confirm through SupportsShouldProcess; -WhatIf writes no files.

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
One or more recipients recorded as the new scope group's owners in the config.

.PARAMETER GroupPrefix
Prefix recorded for building the new scope group name. When
omitted, defaults to 'UDLRAo1P' (DistributionList) or 'Um365RAo1P' (M365Group) based on
-AccessGroupType.

.PARAMETER AccessGroupType
Kind of group to create later for the new RBAC scope.
(M365Group or DistributionList). Defaults to DistributionList (matching New-RBAC4AppEntry).
MailEnabledSecurityGroup is not offered here: conversion mints a new scope group per policy,
whereas a MailEnabledSecurityGroup references a single pre-existing on-prem/hybrid-synced group
by name.

.PARAMETER OutputPath
Directory to write config files into. Defaults to the current working directory.

.PARAMETER Format
Config format: Yaml (default, .yml) or Json (.json). Files use the rbac4app prefix,
sanitized application and source group names, AppId, timestamp, and a unique suffix.

.EXAMPLE
Convert-ApplicationAccessPolicyToRBAC -WhatIf -Verbose

Shows the planned conversion for every Application Access Policy without making changes.

.EXAMPLE
Get-ApplicationAccessPolicy | Convert-ApplicationAccessPolicyToRBAC

Writes a config for every convertible Application Access Policy piped in.

.EXAMPLE
Convert-ApplicationAccessPolicyToRBAC -AppId '11111111-2222-3333-4444-555555555555' -Role 'Mail.Send'

Generates configs for one app, recording the explicit Application Mail.Send role
instead of deriving roles from the app's Graph permission grants.

.OUTPUTS
PSCustomObject

Returns one summary object per processed policy with the resolved identity, access right,
scope group, derived roles, skipped permissions, copied members, ConfigPath, warnings, and errors.
Pass ConfigPath to Invoke-RBAC4AppConfig in an Exchange-Online-only session.

.NOTES
Requires connected Microsoft Graph (Get-MgServicePrincipal,
Get-MgServicePrincipalAppRoleAssignment, Get-MgContext) and Exchange Online
(Get-ApplicationAccessPolicy, Get-DistributionGroupMember) read access.
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
        [string[]] $ManagedBy = @('GraphAPI-Dummy-owner'),

        [Parameter()]
        [string] $GroupPrefix = $null,

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList')]
        [string] $AccessGroupType = 'DistributionList',

        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [ValidateSet('Yaml', 'Json')]
        [string] $Format = 'Yaml'
    )

    begin {
        if (-not $OutputPath) { $OutputPath = (Get-Location).Path }
        $legacyRoleMap = Get-LegacyScopeRoleMap
        # Cache resource service principals (e.g. Microsoft Graph) by ResourceId so the
        # AppRoleId -> permission value lookup only fetches each resource SP once.
        $resourceSpCache = @{}

        # Collect piped policies so non-pipeline filtering still works in end{}.
        $pipedPolicies = [System.Collections.Generic.List[object]]::new()

        if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) {
            $GroupPrefix = switch ($AccessGroupType) {
                'DistributionList' { 'UDLRAo1P' }
                default            { 'Um365RAo1P' }
            }
        }
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
                ConfigPath         = $null
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
                        throw $memberWarn
                    }
                }
                $result.MembersCopied = @($members)

                # --- Build the same schema consumed by Invoke-RBAC4AppConfig
                $tenantId = ''
                try { $tenantId = (Get-MgContext -ErrorAction Stop).TenantId }
                catch { Write-Verbose "TenantId unavailable: $($_.Exception.Message)" }
                $config = [pscustomobject]@{
                    SchemaVersion = '4.0'
                    GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
                    TenantId      = $tenantId
                    Application   = [pscustomobject]@{
                        AppId       = [string]$sp.AppId
                        SpObjectId  = [string]$sp.Id
                        DisplayName = [string]$sp.DisplayName
                    }
                    Rbac = [pscustomobject]@{ Roles = $rolesNormalized }
                    RbacScope = [pscustomobject]@{
                        AccessGroupType       = $AccessGroupType
                        GroupPrefix           = $GroupPrefix
                        AccessGroupName       = ''
                        Members               = $members
                        ManagedBy             = $ManagedBy
                        BootstrapMember       = 'GraphAPI-Dummy'
                        ScopeKind             = 'Group'
                        ManagementScopeName   = ''
                        ManagementScopePrefix = 'MSRAo1P'
                        ScopeRecipients       = @()
                        ScopeTagAttribute     = 'CustomAttribute1'
                        ScopeTagValue         = ''
                        ScopeFilter           = ''
                    }
                }
                $extension = if ($Format -eq 'Json') { 'json' } else { 'yml' }
                $safeName = Get-SafeName -s $sp.DisplayName -max 40
                $safeScope = Get-SafeName -s $pol.ScopeName -max 40
                $safeAppId = Get-SafeName -s $polAppId -max 36
                $timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
                $uniqueId = [guid]::NewGuid().ToString('N')
                $outFile = Join-Path $OutputPath "rbac4app-$safeName-$safeScope-$safeAppId-$timestamp-$uniqueId.$extension"
                $serialized = if ($Format -eq 'Json') { $config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $config }

                if ($PSCmdlet.ShouldProcess($outFile, "Write RBAC4App config ($Format) from Application Access Policy")) {
                    [System.IO.File]::WriteAllText($outFile, $serialized, [System.Text.Encoding]::UTF8)
                    $result.ConfigPath = $outFile
                    Write-Verbose "Config written to '$outFile'."
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
