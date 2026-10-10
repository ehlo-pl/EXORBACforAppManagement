<#
.SYNOPSIS
Provisions Exchange Online RBAC from a YAML or JSON config file written by New-RBAC4AppConfig.

.DESCRIPTION
Invoke-RBAC4AppConfig is the ExchangeOnlineManagement half of the two-session workflow.
It reads a config file produced by New-RBAC4AppConfig (which runs in a Microsoft Graph
session) and provisions every Exchange Online resource - scope group creation and member addition
(ScopeKind Group), EXO service principal registration, the management scope, and management role
assignments bound to that scope (-CustomResourceScope) - without calling any Microsoft Graph
cmdlets.

Schema versions 4.0 (current) and 3.0 are accepted. A 3.0 config has no management scope
settings, so it is treated as ScopeKind Group with the default 'MSRAo1P' scope prefix: the role
assignments are bound to a management scope over the scope group's members.

The config file's format (YAML or JSON) is auto-detected from the -Path extension (.json vs
.yml/.yaml) unless -Format overrides it.

This separates the two modules into distinct PowerShell sessions, avoiding the MSAL/WAM
assembly conflict that can occur when both Microsoft.Graph and ExchangeOnlineManagement are
loaded in the same process.

Every creation step is idempotent, matching New-RBAC4AppEntry: the scope group, the EXO service
principal, the management scope, and each role assignment are only created if a matching one does
not already exist - a role assignment that already exists and is bound to the management scope is
left alone (a warning notes it was skipped), an existing management scope whose filter differs is
left unchanged (warned; use Set-RBAC4AppEntry to reconcile), and requested members are still added
to the group regardless.

.PARAMETER Path
Path to the YAML or JSON file produced by New-RBAC4AppConfig.

.PARAMETER Format
Config file format to read: Auto (default, detected from the -Path extension), Yaml, or Json.
Use Yaml/Json to force a format when the file's extension doesn't match its content.

.EXAMPLE
Invoke-RBAC4AppConfig -Path .\rbac4app-ContosoMailApp-202609200830.yml -WhatIf
Invoke-RBAC4AppConfig -Path .\rbac4app-ContosoMailApp-202609200830.yml

.EXAMPLE
Invoke-RBAC4AppConfig -Path .\rbac4app-ContosoMailApp-202609200830.json

.OUTPUTS
PSCustomObject - same summary shape as New-RBAC4AppEntry (ResolvedDisplay, AppId, SpObjectId,
ScopeKind, ManagementScopeName, ManagementScopeFilter, ScopeGroupName, RolesNormalized, RoleAssignmentsName, MembersAdded, MembersFinal, Warnings,
Errors, etc.).
#>
function Invoke-RBAC4AppConfig {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateSet('Auto', 'Yaml', 'Json')]
        [string] $Format = 'Auto'
    )

    begin {
        $shortRoleMap = Get-AppRoleMap
    }

    process {
        # --- Read and validate the config file
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Error "Config file not found: '$Path'"
            return
        }

        $resolvedFormat = $Format
        if ($resolvedFormat -eq 'Auto') {
            $resolvedFormat = if ([System.IO.Path]::GetExtension($Path) -match '(?i)^\.json$') { 'Json' } else { 'Yaml' }
        }

        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        try {
            $config = if ($resolvedFormat -eq 'Json') { $content | ConvertFrom-Json } else { ConvertFrom-RBAC4AppYaml -Content $content }
        }
        catch {
            Write-Error "Config '$Path' could not be parsed as $resolvedFormat`: $($_.Exception.Message)"
            return
        }

        if ([string]$config.SchemaVersion -notin @('3.0', '4.0')) {
            Write-Error "Config '$Path' has SchemaVersion '$($config.SchemaVersion)', but this version of Invoke-RBAC4AppConfig requires '4.0' (or '3.0', treated as ScopeKind Group). Re-generate the config with New-RBAC4AppConfig."
            return
        }
        if (-not $config.Application.SpObjectId) {
            Write-Error "Config '$Path' is missing Application.SpObjectId. Re-generate with New-RBAC4AppConfig."
            return
        }
        if (-not $config.Application.AppId) {
            Write-Error "Config '$Path' is missing Application.AppId. Re-generate with New-RBAC4AppConfig."
            return
        }
        if (-not $config.Application.DisplayName) {
            Write-Error "Config '$Path' is missing Application.DisplayName. Re-generate with New-RBAC4AppConfig."
            return
        }

        $spId          = $config.Application.SpObjectId
        $spAppId       = $config.Application.AppId
        $spDisplayName = $config.Application.DisplayName

        $AccessGroupType = $config.RbacScope.AccessGroupType
        $GroupPrefix     = $config.RbacScope.GroupPrefix
        $AccessGroupName = $config.RbacScope.AccessGroupName
        $Members         = @($config.RbacScope.Members)
        $ManagedBy       = @($config.RbacScope.ManagedBy)
        $BootstrapMember = $config.RbacScope.BootstrapMember
        $roles           = @($config.Rbac.Roles)
        $ChangeReference = [string]$config.Rbac.ChangeReference

        # --- Management scope settings (schema 4.0; absent from 3.0 -> Group kind, default prefix)
        $ScopeKind = if ([string]$config.RbacScope.ScopeKind) { [string]$config.RbacScope.ScopeKind } else { 'Group' }
        if ($ScopeKind -notin @('Group', 'Recipients', 'Tag', 'Filter')) {
            Write-Error "Config '$Path' has unsupported RbacScope.ScopeKind '$ScopeKind' (expected Group, Recipients, Tag, or Filter)."
            return
        }
        $ManagementScopeName   = [string]$config.RbacScope.ManagementScopeName
        $ManagementScopePrefix = if ([string]$config.RbacScope.ManagementScopePrefix) { [string]$config.RbacScope.ManagementScopePrefix } else { 'MSRAo1P' }
        $ScopeRecipients       = @($config.RbacScope.ScopeRecipients | Where-Object { $_ })
        $ScopeTagAttribute     = if ([string]$config.RbacScope.ScopeTagAttribute) { [string]$config.RbacScope.ScopeTagAttribute } else { 'CustomAttribute1' }
        $ScopeTagValue         = [string]$config.RbacScope.ScopeTagValue
        $ScopeFilter           = [string]$config.RbacScope.ScopeFilter
        if ($ScopeKind -eq 'Recipients' -and $ScopeRecipients.Count -eq 0) {
            Write-Error "Config '$Path' has ScopeKind Recipients but no RbacScope.ScopeRecipients."
            return
        }
        if ($ScopeKind -eq 'Filter' -and -not $ScopeFilter) {
            Write-Error "Config '$Path' has ScopeKind Filter but no RbacScope.ScopeFilter."
            return
        }
        $isGroupKind = $ScopeKind -eq 'Group'

        $result = [ordered]@{
            ParameterSet        = 'ByConfig'
            IdentityInput       = $Path
            ResolvedDisplay     = $spDisplayName
            AppId               = $spAppId
            SpObjectId          = $spId
            TenantId            = $config.TenantId
            ScopeKind           = $ScopeKind
            ManagementScopeName    = $null
            ManagementScopeFilter  = $null
            ManagementScopeCreated = $false
            AccessGroupType     = if ($isGroupKind) { $AccessGroupType } else { $null }
            ScopeGroupName      = $null
            OwnerRequested      = if ($isGroupKind) { @($ManagedBy) } else { @() }
            OwnerAdded          = $null
            MembersRequested    = if ($isGroupKind) { @($Members) } else { @() }
            MembersAdded        = @()
            MembersFinal        = @()
            FilteredMembers     = @()
            ChangeReference     = $ChangeReference
            ChangeReferencePath = $null
            RolesNormalized     = @()
            RoleAssignments     = @()
            RoleAssignmentsName = @()
            Warnings            = @()
            Errors              = @()
        }

        try {
            $ugResult = $null
            $umGroupName = $null
            if ($isGroupKind) {
                # --- Derive scope group name
                if ($AccessGroupName) {
                    $umGroupName = $AccessGroupName
                }
                elseif ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                    throw "-AccessGroupName is required when AccessGroupType is MailEnabledSecurityGroup. Re-generate the config with -AccessGroupName set."
                }
                else {
                    $umGroupName = Get-SafeName -s ('{0}-{1}' -f $GroupPrefix, $spDisplayName)
                }
                $result.ScopeGroupName = $umGroupName

                # --- Ensure scope group
                Write-Verbose ("Checking {0} '{1}' for service principal '{2}' ({3})." -f $AccessGroupType, $umGroupName, $spDisplayName, $spId)
                $scopeGroupParams = @{
                    AccessGroupType = $AccessGroupType
                    Name            = $umGroupName
                    ManagedBy       = $ManagedBy
                    BootstrapMember = $BootstrapMember
                    WarningVariable = 'ugWarnings'
                }
                if ($ChangeReference) { $scopeGroupParams['ChangeReference'] = $ChangeReference }
                $ugResult = New-RBAC4AppScopeGroup @scopeGroupParams
                foreach ($w in $ugWarnings) {
                    if ([string]$w.Message -like '*already exists*') { $result.Warnings += [string]$w.Message }
                }
                if ($ugResult) {
                    $result.OwnerRequested = $ugResult.OwnerRequested
                    $result.OwnerAdded     = $ugResult.OwnerAdded
                    $result.ChangeReferencePath = $ugResult.ChangeReferencePath
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
                # here, so warn about any group-modifying config value that was ignored.
                if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                    if ($Members -and ($Members | Where-Object { $_ -and $_ -ne 'GraphAPI-Dummy' })) {
                        $skipMsg = "Membership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; Members from config was ignored."
                        $result.Warnings += $skipMsg
                        Write-Warning $skipMsg
                    }
                    if ($ManagedBy -and (@($ManagedBy) -join ',') -ne 'GraphAPI-Dummy-owner') {
                        $skipOwnerMsg = "Ownership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; ManagedBy from config was ignored."
                        $result.Warnings += $skipOwnerMsg
                        Write-Warning $skipOwnerMsg
                    }
                    if ($BootstrapMember -and $BootstrapMember -ne 'GraphAPI-Dummy') {
                        $skipBootstrapMsg = "Initial membership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; BootstrapMember from config was ignored."
                        $result.Warnings += $skipBootstrapMsg
                        Write-Warning $skipBootstrapMsg
                    }
                }
                else {
                    foreach ($member in $Members) {
                        if (-not $member) { continue }
                        $rec = Get-Recipient -Identity $member -ErrorAction SilentlyContinue
                        if (-not $rec) {
                            $result.Warnings += "Recipient not found for '$member' (skipped)."
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
            }

            # --- Register EXO service principal
            $exoSpDisplay = '{0}_SP' -f $spDisplayName
            $null = Register-EXOServicePrincipal -AppId $spAppId -ObjectId $spId -DisplayName $exoSpDisplay

            # --- Ensure the management scope the role assignments are bound to (create-only, like
            # New-RBAC4AppEntry: an existing scope with a different filter is warned about, not changed).
            $scopeName = Get-RBAC4AppManagementScopeName -DisplayName $spDisplayName -Prefix $ManagementScopePrefix -Name $ManagementScopeName
            $result.ManagementScopeName = $scopeName
            $groupDn = if ($ugResult -and $ugResult.Group) { [string]$ugResult.Group.DistinguishedName } else { $null }
            $filterArgs = @{
                ScopeKind              = $ScopeKind
                GroupIdentity          = $umGroupName
                GroupDistinguishedName = $groupDn
                Recipients             = $ScopeRecipients
                TagAttribute           = $ScopeTagAttribute
                TagValue               = if ($ScopeTagValue) { $ScopeTagValue } else { $scopeName }
                Filter                 = $ScopeFilter
                AllowUnresolved        = ($isGroupKind -and [bool]$WhatIfPreference)
            }
            $scopeFilterText = ConvertTo-RBAC4AppRecipientFilter @filterArgs
            $scopeResult = New-RBAC4AppManagementScope -Name $scopeName -RecipientRestrictionFilter $scopeFilterText -NoUpdate -WarningVariable msWarnings
            foreach ($w in $msWarnings) { $result.Warnings += [string]$w.Message }
            $result.ManagementScopeFilter  = $scopeResult.RecipientRestrictionFilter
            $result.ManagementScopeCreated = [bool]$scopeResult.Created

            # --- Role assignments
            $rolesNormalized = @(foreach ($r in $roles) { Get-NormalizeRole $r })
            $result.RolesNormalized = @($rolesNormalized)

            $rbacNameBase = $null
            foreach ($roleItem in $rolesNormalized) {
                $shortName    = $shortRoleMap[$roleItem]
                $rbacNameBase = Get-SafeName -s ('{0}-{1}' -f $shortName, $spDisplayName) -max 63
                $result.RoleAssignmentsName += $rbacNameBase

                # --- Skip creation if a role assignment with this deterministic name already
                # exists, so re-running against an already-provisioned app is idempotent. Members
                # were already added above regardless of this check.
                $existingAssignments = @(Get-ManagementRoleAssignment -Identity $rbacNameBase -ErrorAction SilentlyContinue)
                if ($existingAssignments.Count -gt 0) {
                    if ($existingAssignments.Count -gt 1) {
                        $existsMsg = "Role assignment '$rbacNameBase' lookup returned $($existingAssignments.Count) entries; expected 1. Resolve duplicate assignments before retrying."
                        $result.Errors += $existsMsg
                        continue
                    }
                    $existingAssignment = $existingAssignments[0]
                    if ([string]$existingAssignment.Role -and ([string]$existingAssignment.Role -ine $roleItem)) {
                        $existsMsg = "Role assignment '$rbacNameBase' already exists but is bound to role '$([string]$existingAssignment.Role)', not '$roleItem'."
                        $result.Errors += $existsMsg
                        continue
                    }
                    $scopeState = Get-RBAC4AppAssignmentScopeState -Assignment $existingAssignment -ManagementScopeName $scopeName -LegacyGroupName $umGroupName
                    switch ($scopeState.State) {
                        'Target' {
                            $existsMsg = "Role assignment '$rbacNameBase' already exists and is scoped to management scope '$scopeName'; skipping creation."
                        }
                        'LegacyGroup' {
                            $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped directly to group '$umGroupName' (legacy -RecipientGroupScope); leaving it as-is. Run Set-RBAC4AppEntry to migrate it to management scope '$scopeName'."
                        }
                        default {
                            $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped to '$($scopeState.CurrentScope)', not management scope '$scopeName'; leaving it as-is. Use Set-RBAC4AppEntry to re-scope it."
                        }
                    }
                    $result.Warnings += $existsMsg
                    Write-Warning -Message $existsMsg
                    $result.RoleAssignments += $existingAssignment
                    continue
                }

                if ($PSCmdlet.ShouldProcess('RBAC role assignment', "Assign '$roleItem' to App '$spDisplayName' scoped to management scope '$scopeName'")) {
                    $assignment = New-ManagementRoleAssignment `
                        -App $spId `
                        -Role $roleItem `
                        -CustomResourceScope $scopeName `
                        -Name $rbacNameBase `
                        -ErrorAction Stop
                    $result.RoleAssignments += $assignment
                }
            }

            [pscustomobject]$result
            if ($rbacNameBase) {
                $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}_{1}.clixml" -f $rbacNameBase, (Get-Date -Format s).Replace(':', ''))
                [pscustomobject]$result | Export-Clixml $exportPath -Verbose
            }
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
