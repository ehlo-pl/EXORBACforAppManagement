<#
.SYNOPSIS
Generates RBAC configuration files from legacy Exchange Online Application Access Policies.

.DESCRIPTION
Convert-ApplicationAccessPolicyToRBAC reads existing Application Access Policy entries
(via Get-ApplicationAccessPolicy) and writes schema 4.4 configuration files, like
New-RBAC4AppConfig, for later provisioning with Invoke-RBAC4AppConfig. Each file also carries the
policy's full conversion result: its ConversionResult section holds AppId, ResolvedDisplay,
AccessRight, ScopeGroup, DerivedRoles, SkippedPermissions, and ConfigPath (the file itself), and
the Runtime section holds the Warnings/Errors as CollectedWarnings/CollectedErrors.

For each RestrictAccess policy it resolves the Entra service principal, derives the
Exchange Online application roles from the app's granted Microsoft Graph application
permissions (filtered to the set that Application Access Policies supported and mapped to
their App RBAC role names via the private Get-LegacyScopeRoleMap), and records the roles in
YAML or JSON scoped directly to the policy's existing ScopeName group (ScopeKind Group,
AssignmentScope RecipientGroupScope). No Exchange Online objects are created or changed.
DenyAccess policies have no additive RBAC equivalent and are skipped with a warning.

The migration always keeps the group the policy uses today. Every config records the policy's
ScopeName verbatim as AccessGroupName with AccessGroupType HybridMailEnabledSecurityGroup - the
reference-only group type - so Invoke-RBAC4AppConfig only checks that the group exists
(Get-Recipient -Identity <ScopeName>) and fails if it does not; it never creates, renames,
re-configures, or changes the membership or owners of that group, and it never sanitizes or
shortens its name. A policy without a ScopeName is reported as an error instead of being given
a newly named group.

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
Deprecated and ignored (a warning is written when supplied). The policy's existing ScopeName
group is always reused as-is, so its owners are never changed.

.PARAMETER GroupPrefix
Deprecated and ignored (a warning is written when supplied). No group name is ever derived: the
policy's ScopeName is always used, and a policy without one is reported as an error.

.PARAMETER AccessGroupType
Deprecated and ignored (a warning is written when supplied). Every config records
AccessGroupType HybridMailEnabledSecurityGroup, the reference-only type, so the existing ScopeName group
is validated but never created or modified.

.PARAMETER OutputPath
Directory to write config files into. Defaults to the current working directory.

.PARAMETER Format
Config format: Yaml (default, .yml), Json (.json), or M365DSC (the YAML config plus a
Microsoft365DSC configuration script, .ps1, same name; its path is returned as DscPath. The policy's
group is only referenced there and its distinguished name is a Configuration parameter). Files use the rbac4app prefix,
sanitized application and source group names, AppId, timestamp, and a unique suffix.

.PARAMETER DscAuthentication
How the Microsoft365DSC script written by -Format M365DSC signs in to Exchange Online:
ManagedIdentity (default; ManagedIdentity + TenantId on every resource - runs only on a machine with
a managed identity) or Certificate (ApplicationId + TenantId + CertificateThumbprint Configuration
parameters - runs on any machine holding the app's certificate). No secret is written either way.
Only valid with -Format M365DSC.

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
scope group, derived roles, skipped permissions, ConfigPath, warnings, and errors.
Pass ConfigPath to Invoke-RBAC4AppConfig in an Exchange-Online-only session. The same fields are
written into the config file (ConversionResult and Runtime sections). ConfigPath on the returned
object stays empty under -WhatIf, while the ConversionResult.ConfigPath that would be written always
names the target file.

.NOTES
Requires connected Microsoft Graph (Get-MgServicePrincipal,
Get-MgServicePrincipalAppRoleAssignment, Get-MgContext) and Exchange Online
(Get-ApplicationAccessPolicy) read access.
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
        [ValidateSet('Yaml', 'Json', 'M365DSC')]
        [string] $Format = 'Yaml',

        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string] $DscAuthentication = 'ManagedIdentity'
    )

    begin {
        if ($PSBoundParameters.ContainsKey('DscAuthentication') -and $Format -ne 'M365DSC') {
            throw '-DscAuthentication can only be used with -Format M365DSC.'
        }
        if (-not $OutputPath) { $OutputPath = (Get-Location).Path }
        $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $legacyRoleMap = Get-LegacyScopeRoleMap
        # Cache resource service principals (e.g. Microsoft Graph) by ResourceId so the
        # AppRoleId -> permission value lookup only fetches each resource SP once.
        $resourceSpCache = @{}

        # Collect piped policies so non-pipeline filtering still works in end{}.
        $pipedPolicies = [System.Collections.Generic.List[object]]::new()

        # The existing policy scope group is always kept: these no longer influence the config.
        foreach ($ignored in @('AccessGroupType', 'GroupPrefix', 'ManagedBy')) {
            if ($PSBoundParameters.ContainsKey($ignored)) {
                Write-Warning -Message ("-{0} is deprecated and ignored: every config reuses the policy's existing ScopeName group as-is (AccessGroupType HybridMailEnabledSecurityGroup, never created or modified)." -f $ignored)
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
                ConfigPath         = $null
                DscPath            = $null
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

                # --- The policy's current scope group is what the RBAC assignments must keep using.
                $scopeGroupName = [string]$pol.ScopeName
                if ([string]::IsNullOrWhiteSpace($scopeGroupName)) {
                    throw "Policy for AppId '$polAppId' has no ScopeName, so there is no existing scope group to keep; no config was written."
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
                    $rolesNormalized = @($Role | ForEach-Object { ConvertTo-RBAC4AppRoleName -Role $_ } | Select-Object -Unique)
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

                # --- Build the same schema consumed by Invoke-RBAC4AppConfig. HybridMailEnabledSecurityGroup
                # is the reference-only group type: Invoke-RBAC4AppConfig looks the group up by this
                # exact name, never creates it, never sanitizes/shortens the name, and never touches
                # its members or owners - so the migrated assignments keep using today's group.
                $tenantId = ''
                try { $tenantId = (Get-MgContext -ErrorAction Stop).TenantId }
                catch { Write-Verbose "TenantId unavailable: $($_.Exception.Message)" }
                $extension = if ($Format -eq 'Json') { 'json' } else { 'yml' }
                $safeName = Format-RBAC4AppSafeName -Value $sp.DisplayName -MaxLength 40
                $safeScope = Format-RBAC4AppSafeName -Value $pol.ScopeName -MaxLength 40
                $safeAppId = Format-RBAC4AppSafeName -Value $polAppId -MaxLength 36
                $timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
                $uniqueId = [guid]::NewGuid().ToString('N')
                $outFile = Join-Path $OutputPath "rbac4app-$safeName-$safeScope-$safeAppId-$timestamp-$uniqueId.$extension"

                # The file carries this policy's full conversion result: ConversionResult holds the
                # result fields (ConfigPath = the file being written) and Runtime its Warnings/Errors.
                $conversionResult = [pscustomobject]$result
                $conversionResult.ConfigPath = $outFile
                # DscPath is a result field only; the config's ConversionResult section keeps its schema.
                $conversionResult.PSObject.Properties.Remove('DscPath')
                $config = ConvertTo-RBAC4AppConfig `
                    -TenantId $tenantId `
                    -AppId ([string]$sp.AppId) -SpObjectId ([string]$sp.Id) -DisplayName ([string]$sp.DisplayName) `
                    -Roles $rolesNormalized `
                    -AccessGroupType 'HybridMailEnabledSecurityGroup' `
                    -GroupPrefix (Get-RBAC4AppDefaultGroupPrefix -AccessGroupType 'HybridMailEnabledSecurityGroup') `
                    -AccessGroupName $scopeGroupName `
                    -AssignmentScope RecipientGroupScope `
                    -CollectedWarnings @($result.Warnings) `
                    -CollectedErrors @($result.Errors) `
                    -ConversionResult $conversionResult
                $serialized = if ($Format -eq 'Json') { $config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $config }

                $dscScript = $null
                if ($Format -eq 'M365DSC') {
                    $dsc = ConvertTo-RBAC4AppM365Dsc -Config $config -Authentication $DscAuthentication
                    foreach ($dscWarning in $dsc.Warnings) { $result.Warnings += $dscWarning }
                    $dscScript = $dsc.Script
                }

                if ($PSCmdlet.ShouldProcess($outFile, "Write RBAC4App config ($Format) from Application Access Policy")) {
                    [System.IO.File]::WriteAllText($outFile, $serialized, [System.Text.Encoding]::UTF8)
                    $result.ConfigPath = $outFile
                    Write-Verbose "Config written to '$outFile'."
                    if ($dscScript) {
                        $dscFile = [System.IO.Path]::ChangeExtension($outFile, '.ps1')
                        [System.IO.File]::WriteAllText($dscFile, $dscScript, [System.Text.Encoding]::UTF8)
                        $result.DscPath = $dscFile
                        Write-Verbose "Microsoft365DSC configuration written to '$dscFile'."
                    }
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
