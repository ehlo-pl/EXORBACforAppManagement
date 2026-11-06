<#
.SYNOPSIS
Provisions Exchange Online RBAC from a YAML or JSON config file written by New-RBAC4AppConfig.

.DESCRIPTION
Invoke-RBAC4AppConfig is the ExchangeOnlineManagement half of the two-session workflow.
It reads a config file produced by New-RBAC4AppConfig (which runs in a Microsoft Graph
session) and provisions every Exchange Online resource - scope group creation and member addition
(ScopeKind Group), EXO service principal registration, and management role assignments - without
calling any Microsoft Graph cmdlets. RbacScope.AssignmentScope selects how the assignments are
bound: RecipientGroupScope binds them directly to the scope group (-RecipientGroupScope, no
management scope; ScopeKind Group only), ManagementScope creates the management scope and binds
them to it (-CustomResourceScope).

The optional Metadata section (contacts, PCode, CMDB ID, description, network access) is validated
and returned in the result's Metadata property; it never affects provisioning.

Schema versions 4.2 (current), 4.1, 4.0, and 3.0 are accepted. 4.0 and 3.0 configs have no
AssignmentScope and are treated as ManagementScope. A 3.0 config also has no management scope
settings, so it is treated as ScopeKind Group with the default 'MSRAo1P' scope prefix: the role
assignments are bound to a management scope over the scope group's members.

The config file's format (YAML or JSON) is auto-detected from the -Path extension (.json vs
.yml/.yaml) unless -Format overrides it.
Files containing an array of schema-compatible configs are also accepted and each entry is
provisioned independently.

This separates the two modules into distinct PowerShell sessions, avoiding the MSAL/WAM
assembly conflict that can occur when both Microsoft.Graph and ExchangeOnlineManagement are
loaded in the same process.

Every creation step is idempotent, matching New-RBAC4AppEntry: the scope group, the EXO service
principal, the management scope, and each role assignment are only created if a matching one does
not already exist - a role assignment that already exists and is bound to the configured scope
(the management scope, or the scope group for RecipientGroupScope) is left alone (a warning notes
it was skipped), an existing management scope whose filter differs is
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
Errors, etc.). When SeparateScopePerRole is enabled, ScopeGroupNames, ManagementScopeNames, and
RoleScopes report the per-role resources.
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
            $config = if ($resolvedFormat -eq 'Json' -or $content.TrimStart().StartsWith('[')) {
                $content | ConvertFrom-Json
            }
            else {
                ConvertFrom-RBAC4AppYaml -Content $content
            }
        }
        catch {
            Write-Error "Config '$Path' could not be parsed as $resolvedFormat`: $($_.Exception.Message)"
            return
        }

        if ($config -is [array]) {
            $originalConfirmPreference = $ConfirmPreference
            if ($PSBoundParameters.ContainsKey('Confirm') -and -not $Confirm) {
                $ConfirmPreference = 'None'
            }
            try {
                foreach ($configEntry in $config) {
                    $entryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rbac4app-{0}.json" -f [guid]::NewGuid().ToString('N'))
                    try {
                        $entryJson = ConvertTo-Json -InputObject $configEntry -Depth 6
                        [System.IO.File]::WriteAllText($entryPath, $entryJson, [System.Text.Encoding]::UTF8)
                        $invokeParameters = @{ Path = $entryPath; Format = 'Json' }
                        if ($WhatIfPreference) { $invokeParameters.WhatIf = $true }
                        if ($PSBoundParameters.ContainsKey('Confirm') -and $Confirm) { $invokeParameters.Confirm = $true }
                        foreach ($entryResult in @(Invoke-RBAC4AppConfig @invokeParameters)) {
                            if ($entryResult -and $entryResult.PSObject.Properties['IdentityInput']) {
                                $entryResult.IdentityInput = $Path
                            }
                            $entryResult
                        }
                    }
                    finally {
                        Remove-Item -LiteralPath $entryPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            finally {
                $ConfirmPreference = $originalConfirmPreference
            }
            return
        }

        # Keys left out of the file (ConvertTo-RBAC4AppConfig omits unused/default entries) take
        # their defaults; YAML input already went through this in ConvertFrom-RBAC4AppYaml.
        $config = Complete-RBAC4AppConfig -Config $config

        if ([string]$config.SchemaVersion -notin $script:RBAC4AppConfigSupportedSchemaVersions) {
            Write-Error "Config '$Path' has SchemaVersion '$($config.SchemaVersion)', but this version of Invoke-RBAC4AppConfig requires '$($script:RBAC4AppConfigSchemaVersion)' (or '4.1', or '4.0'/'3.0', treated as AssignmentScope ManagementScope). Re-generate the config with New-RBAC4AppConfig."
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
        $separateScopePerRole = ([string]$config.RbacScope.SeparateScopePerRole -eq 'true')

        # --- Management scope settings (schema 4.0; absent from 3.0 -> Group kind, default prefix)
        $ScopeKind = [string]$config.RbacScope.ScopeKind
        if ($ScopeKind -notin @('Group', 'Recipients', 'Tag', 'Filter')) {
            Write-Error "Config '$Path' has unsupported RbacScope.ScopeKind '$ScopeKind' (expected Group, Recipients, Tag, or Filter)."
            return
        }
        $ManagementScopeName   = [string]$config.RbacScope.ManagementScopeName
        $ManagementScopePrefix = [string]$config.RbacScope.ManagementScopePrefix
        $ScopeRecipients       = @($config.RbacScope.ScopeRecipients | Where-Object { $_ })
        $ScopeTagAttribute     = [string]$config.RbacScope.ScopeTagAttribute
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
        if ($separateScopePerRole -and -not $isGroupKind) {
            Write-Error "Config '$Path' has SeparateScopePerRole enabled but ScopeKind is '$ScopeKind'; this option requires ScopeKind Group."
            return
        }
        # --- Assignment binding (absent -> RecipientGroupScope for a 4.1 Group config, else
        # ManagementScope; resolved by Complete-RBAC4AppConfig)
        $AssignmentScope = [string]$config.RbacScope.AssignmentScope
        if ($AssignmentScope -notin @('ManagementScope', 'RecipientGroupScope')) {
            Write-Error "Config '$Path' has unsupported RbacScope.AssignmentScope '$AssignmentScope' (expected ManagementScope or RecipientGroupScope)."
            return
        }
        if ($AssignmentScope -eq 'RecipientGroupScope' -and -not $isGroupKind) {
            Write-Error "Config '$Path' has AssignmentScope RecipientGroupScope but ScopeKind is '$ScopeKind'; this option requires ScopeKind Group."
            return
        }
        $isDirectGroup = $AssignmentScope -eq 'RecipientGroupScope'
        $rolesNormalized = @(foreach ($r in $roles) { ConvertTo-RBAC4AppRoleName -Role $r })

        # --- Descriptive metadata: re-checked because the file may have been edited by hand
        $appMetadata = $config.Metadata
        if ($appMetadata.Description -match '[\r\n]') {
            Write-Error "Config '$Path' has a Metadata.Description containing a line break; descriptions must be single-line."
            return
        }
        if ($appMetadata.PCode -and $appMetadata.PCode -notmatch '^P[0-9]{5}$') {
            Write-Error "Config '$Path' has an invalid Metadata.PCode '$($appMetadata.PCode)' (expected 'P' followed by 5 digits)."
            return
        }
        $appMetadata.PCode = $appMetadata.PCode.ToUpperInvariant()
        if ($appMetadata.CmdbId -and $appMetadata.CmdbId -notmatch '^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$') {
            Write-Error "Config '$Path' has an invalid Metadata.CmdbId '$($appMetadata.CmdbId)' (expected a GUID)."
            return
        }
        if ($appMetadata.NetworkAccessIPRange -and $appMetadata.NetworkAccessIPRange -notmatch '^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\/(3[0-2]|[12]?\d))?$') {
            Write-Error "Config '$Path' has an invalid Metadata.NetworkAccessIPRange '$($appMetadata.NetworkAccessIPRange)' (expected an IPv4 address or CIDR range)."
            return
        }
        if ($appMetadata.NetworkAccessLocation) {
            try {
                $validLocations = Get-RBAC4AppLocationList
            }
            catch {
                Write-Error "Could not load the location list to validate Metadata.NetworkAccessLocation: $($_.Exception.Message)"
                return
            }
            $matchedLocation = $validLocations | Where-Object { $_ -ieq $appMetadata.NetworkAccessLocation } | Select-Object -First 1
            if (-not $matchedLocation) {
                Write-Error "Config '$Path' has an unrecognised Metadata.NetworkAccessLocation '$($appMetadata.NetworkAccessLocation)'. Valid locations: $($validLocations -join ', ')"
                return
            }
            $appMetadata.NetworkAccessLocation = $matchedLocation
        }

        $result = [ordered]@{
            ParameterSet        = 'ByConfig'
            IdentityInput       = $Path
            ResolvedDisplay     = $spDisplayName
            AppId               = $spAppId
            SpObjectId          = $spId
            TenantId            = $config.TenantId
            ScopeKind           = $ScopeKind
            AssignmentScope     = $AssignmentScope
            ManagementScopeName    = $null
            ManagementScopeFilter  = $null
            ManagementScopeCreated = $false
            AccessGroupType     = if ($isGroupKind) { $AccessGroupType } else { $null }
            ScopeGroupName      = $null
            ScopeGroupNames     = @()
            OwnerRequested      = if ($isGroupKind) { @($ManagedBy) } else { @() }
            OwnerAdded          = $null
            MembersRequested    = if ($isGroupKind) { @($Members) } else { @() }
            MembersAdded        = @()
            MembersFinal        = @()
            FilteredMembers     = @()
            ChangeReference     = $ChangeReference
            ChangeReferencePath = $null
            Metadata            = $appMetadata
            RolesNormalized     = @()
            ManagementScopeNames = @()
            RoleScopes          = @()
            RoleAssignments     = @()
            RoleAssignmentsName = @()
            Warnings            = @()
            Errors              = @()
        }

        try {
            $rolesNormalized = @($rolesNormalized)
            $result.RolesNormalized = @($rolesNormalized)
            $scopeRoleItems = if ($separateScopePerRole) { @($rolesNormalized | Select-Object -Unique) } else { @('SharedScope') }
            $scopeContexts = @()

            # --- Register EXO service principal
            $exoSpDisplay = '{0}_SP' -f $spDisplayName
            $null = Register-EXOServicePrincipal -AppId $spAppId -ObjectId $spId -DisplayName $exoSpDisplay

            foreach ($scopeRole in $scopeRoleItems) {
                $roleSuffix = if ($separateScopePerRole) { [string]$shortRoleMap[$scopeRole] } else { '' }
                $ugResult = $null
                $umGroupName = $null

                if ($isGroupKind) {
                    # --- Derive a scope group name, retaining the role suffix within the length limit.
                    $groupSuffix = if ($roleSuffix) { "-$roleSuffix" } else { '' }
                    if ($AccessGroupName) {
                        # An explicit name is used as-is unless a role suffix forces a re-cut.
                        $umGroupName = if ($groupSuffix) {
                            (Format-RBAC4AppSafeName -Value $AccessGroupName -MaxLength ($script:RBAC4AppNameMaxLength.Group - $groupSuffix.Length)) + $groupSuffix
                        }
                        else { $AccessGroupName }
                    }
                    elseif ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                        throw "-AccessGroupName is required when AccessGroupType is MailEnabledSecurityGroup. Re-generate the config with -AccessGroupName set."
                    }
                    else {
                        $umGroupName = Get-RBAC4AppScopeGroupName -Prefix $GroupPrefix -DisplayName $spDisplayName -Suffix $groupSuffix
                    }
                    $result.ScopeGroupNames += $umGroupName
                    if (-not $result.ScopeGroupName) { $result.ScopeGroupName = $umGroupName }

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
                        if (-not $result.OwnerAdded) {
                            $result.OwnerRequested = $ugResult.OwnerRequested
                            $result.OwnerAdded     = $ugResult.OwnerAdded
                            $result.ChangeReferencePath = $ugResult.ChangeReferencePath
                        }
                    }

                    # --- Read membership once for this scope group.
                    $existingLinks = if ($AccessGroupType -eq 'M365Group') {
                        @(Get-UnifiedGroupLinks -Identity $umGroupName -LinkType Members -ErrorAction SilentlyContinue)
                    }
                    else {
                        @(Get-DistributionGroupMember -Identity $umGroupName -ErrorAction SilentlyContinue)
                    }
                    $existingMemberIdentities = @($existingLinks | ForEach-Object {
                            if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
                        } | Where-Object { $_ } | Select-Object -Unique)

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

                    $result.MembersFinal = @($result.MembersFinal + $existingMemberIdentities + $result.MembersAdded | Select-Object -Unique)
                }

                # --- Ensure the management scope the role assignments are bound to. Direct group
                # binding still derives the name (to recognise an assignment already bound to it)
                # but creates no scope.
                $scopeSuffix = if ($roleSuffix) { "-$roleSuffix" } else { '' }
                $scopeName = Get-RBAC4AppManagementScopeName -DisplayName $spDisplayName -Prefix $ManagementScopePrefix -Name $ManagementScopeName -Suffix $scopeSuffix
                $scopeContexts += [pscustomobject]@{
                    Role      = $scopeRole
                    GroupName = $umGroupName
                    ScopeName = $scopeName
                }
                if ($isDirectGroup) {
                    if ($separateScopePerRole) {
                        $result.RoleScopes += [pscustomobject]@{
                            Role                = $scopeRole
                            ScopeGroupName      = $umGroupName
                            ManagementScopeName = $null
                        }
                    }
                    continue
                }
                $result.ManagementScopeNames += $scopeName
                if (-not $result.ManagementScopeName) { $result.ManagementScopeName = $scopeName }
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
                if (-not $result.ManagementScopeFilter) { $result.ManagementScopeFilter = $scopeResult.RecipientRestrictionFilter }
                $result.ManagementScopeCreated = [bool]($result.ManagementScopeCreated -or $scopeResult.Created)
                if ($separateScopePerRole) {
                    $result.RoleScopes += [pscustomobject]@{
                        Role               = $scopeRole
                        ScopeGroupName     = $umGroupName
                        ManagementScopeName = $scopeName
                    }
                }
            }

            # --- Role assignments
            $rbacNameBase = $null
            foreach ($roleItem in $rolesNormalized) {
                $roleContext = if ($separateScopePerRole) {
                    $scopeContexts | Where-Object { $_.Role -eq $roleItem } | Select-Object -First 1
                }
                else {
                    $scopeContexts[0]
                }
                $scopeName = $roleContext.ScopeName
                $umGroupName = $roleContext.GroupName
                $shortName    = $shortRoleMap[$roleItem]
                $rbacNameBase = Get-RBAC4AppRoleAssignmentName -ShortRoleName $shortName -DisplayName $spDisplayName
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
                    if ($isDirectGroup) {
                        $existsMsg = if ($scopeState.State -eq 'LegacyGroup') {
                            "Role assignment '$rbacNameBase' already exists and is scoped directly to group '$umGroupName'; skipping creation."
                        }
                        else {
                            "Role assignment '$rbacNameBase' already exists but is scoped to '$($scopeState.CurrentScope)', not directly to group '$umGroupName'; leaving it as-is. Use Set-RBAC4AppEntry to re-scope it."
                        }
                    }
                    else {
                        switch ($scopeState.State) {
                            'Target' {
                                $existsMsg = "Role assignment '$rbacNameBase' already exists and is scoped to management scope '$scopeName'; skipping creation."
                            }
                            'LegacyGroup' {
                                $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped directly to group '$umGroupName'; leaving it as-is. Run Set-RBAC4AppEntry -AssignmentScope ManagementScope to move it to management scope '$scopeName'."
                            }
                            default {
                                $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped to '$($scopeState.CurrentScope)', not management scope '$scopeName'; leaving it as-is. Use Set-RBAC4AppEntry -AssignmentScope ManagementScope to re-scope it."
                            }
                        }
                    }
                    $result.Warnings += $existsMsg
                    Write-Warning -Message $existsMsg
                    $result.RoleAssignments += $existingAssignment
                    continue
                }

                if ($isDirectGroup) {
                    if ($PSCmdlet.ShouldProcess('RBAC role assignment', "Assign '$roleItem' to App '$spDisplayName' scoped directly to group '$umGroupName'")) {
                        $assignment = New-ManagementRoleAssignment `
                            -App $spId `
                            -Role $roleItem `
                            -RecipientGroupScope $umGroupName `
                            -Name $rbacNameBase `
                            -ErrorAction Stop
                        $result.RoleAssignments += $assignment
                    }
                }
                elseif ($PSCmdlet.ShouldProcess('RBAC role assignment', "Assign '$roleItem' to App '$spDisplayName' scoped to management scope '$scopeName'")) {
                    $assignment = New-ManagementRoleAssignment `
                        -App $spId `
                        -Role $roleItem `
                        -CustomResourceScope $scopeName `
                        -Name $rbacNameBase `
                        -ErrorAction Stop
                    $result.RoleAssignments += $assignment
                }
            }

            if ($rbacNameBase) {
                # The random id keeps runs in the same second from colliding on one file.
                $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}_{1}_{2}.clixml" -f $rbacNameBase, (Get-Date -Format s).Replace(':', ''), [guid]::NewGuid().ToString('N').Substring(0, 8))
                try {
                    [pscustomobject]$result | Export-Clixml $exportPath -Verbose -ErrorAction Stop
                }
                catch {
                    $result.Warnings += "Could not export the summary to '$exportPath': $($_.Exception.Message)"
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
