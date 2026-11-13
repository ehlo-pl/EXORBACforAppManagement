function ConvertTo-RBAC4AppDscLiteral {
    # Renders a value as PowerShell source for a generated DSC script: a single-quoted string
    # literal (strings), @('a', 'b') (lists), or $true/$false. Values come from application display
    # names, group names and filters - untrusted input - so nothing is ever emitted unquoted or in
    # an expandable string. Every character PowerShell accepts as a single quote (the ASCII one and
    # the typographic U+2018/2019/201A/201B) is doubled so it cannot end the literal.
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Value,

        [Parameter()]
        [switch] $AsList
    )

    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($AsList -or ($Value -is [array])) {
        $items = @($Value | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-RBAC4AppDscLiteral -Value ([string]$_) })
        return '@({0})' -f ($items -join ', ')
    }
    $text = [string]$Value
    $quoteChars = [char[]](0x27, 0x2018, 0x2019, 0x201A, 0x201B)
    $builder = [System.Text.StringBuilder]::new("'")
    foreach ($character in $text.ToCharArray()) {
        [void]$builder.Append($character)
        if ($character -in $quoteChars) { [void]$builder.Append($character) }
    }
    $builder.Append("'").ToString()
}

function ConvertTo-RBAC4AppM365Dsc {
    # Renders one RBAC4App config (schema 4.4, sparse or complete) as a Microsoft365DSC configuration
    # script: EXOServicePrincipal, the scope group (EXODistributionGroup - cloud security group or
    # distribution list only), EXOManagementScope and one EXOManagementRoleAssignment per role.
    # Pure: no Exchange Online or Graph call. Returns { ConfigurationName; Script; Warnings }.
    #
    # Differences from Invoke-RBAC4AppConfig, each also returned as a warning:
    #   - EXOManagementRoleAssignment has no RecipientGroupScope, so every assignment is bound to a
    #     management scope, even for a config whose AssignmentScope is RecipientGroupScope;
    #   - a Group scope needs the group's distinguished name for the MemberOfGroup filter: it is a
    #     Configuration parameter (defaulted from -ScopeGroupDistinguishedName when known);
    #   - EXODistributionGroup Members is authoritative, not additive;
    #   - an M365Group / HybridMailEnabledSecurityGroup is only referenced, never declared.
    # Authentication is ManagedIdentity + TenantId (default) or, with -Authentication Certificate,
    # ApplicationId + TenantId + CertificateThumbprint parameters; no secret is written.
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [psobject] $Config,

        [Parameter()]
        [string] $ScopeGroupDistinguishedName,

        [Parameter()]
        [string] $ConfigurationName,

        # ManagedIdentity: ManagedIdentity + TenantId. Certificate: ApplicationId + TenantId +
        # CertificateThumbprint, all Configuration parameters (the thumbprint is not a secret).
        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string] $Authentication = 'ManagedIdentity'
    )

    $full = Complete-RBAC4AppConfig -Config $Config
    $app = $full.Application
    $scope = $full.RbacScope
    $displayName = [string]$app.DisplayName
    $appId = [string]$app.AppId
    $roles = @($full.Rbac.Roles | Select-Object -Unique)
    if (-not $appId -or -not [string]$app.SpObjectId) { throw 'The config has no Application.AppId / Application.SpObjectId; cannot render a Microsoft365DSC configuration.' }
    if ($roles.Count -eq 0) { throw 'The config has no Rbac.Roles; cannot render a Microsoft365DSC configuration.' }

    $shortRoleMap = Get-AppRoleMap
    foreach ($role in $roles) {
        if (-not $shortRoleMap.Contains($role)) { throw "Role '$role' is not a known application role; cannot derive its role assignment name." }
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $lit = { param($v) ConvertTo-RBAC4AppDscLiteral -Value $v }
    $oneLine = { param($v) ([string]$v) -replace '[\r\n]+', ' ' }
    $instance = { param($v) (([string]$v) -replace '[^A-Za-z0-9_\-]', '_') }

    if (-not $ConfigurationName) {
        $ConfigurationName = 'RBAC4App_' + (($displayName -replace '[^A-Za-z0-9_]', '_').Trim('_'))
        if ($ConfigurationName -eq 'RBAC4App_') { $ConfigurationName = 'RBAC4App_' + ($appId -replace '[^A-Za-z0-9]', '') }
    }
    elseif ($ConfigurationName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        throw "Invalid -ConfigurationName '$ConfigurationName'."
    }

    $isGroupKind = $scope.ScopeKind -eq 'Group'
    $accessGroupType = [string]$scope.AccessGroupType
    $declaresGroup = $isGroupKind -and $accessGroupType -in $script:RBAC4AppDistributionGroupTypes
    $separate = $isGroupKind -and [bool]$scope.SeparateScopePerRole

    if ($isGroupKind -and $scope.AssignmentScope -eq 'RecipientGroupScope') {
        $warnings.Add("Microsoft365DSC: EXOManagementRoleAssignment has no RecipientGroupScope, so the DSC configuration binds the role assignments to a management scope over the group's members (MemberOfGroup) instead of directly to the group as Invoke-RBAC4AppConfig does for this config.")
    }
    if ($isGroupKind -and -not $declaresGroup) {
        $warnings.Add("Microsoft365DSC: the $accessGroupType scope group is only referenced by the DSC configuration, not declared; it must already exist.")
    }
    if ($declaresGroup) {
        $warnings.Add('Microsoft365DSC: EXODistributionGroup Members is authoritative - members not listed in the configuration are removed (Invoke-RBAC4AppConfig only adds), and an owner (ManagedBy) that does not exist as a recipient fails the DSC run instead of skipping the send restriction.')
    }
    if ($scope.ScopeKind -eq 'Recipients') {
        $warnings.Add('Microsoft365DSC: ScopeRecipients are written to the management scope filter as PrimarySmtpAddress values exactly as given (they are not resolved through Get-Recipient); list primary SMTP addresses.')
    }

    # --- One context per management scope (one per role with SeparateScopePerRole, else one shared).
    $contexts = foreach ($scopeRole in $(if ($separate) { $roles } else { @('') })) {
        $short = if ($scopeRole) { [string]$shortRoleMap[$scopeRole] } else { '' }
        $suffix = if ($short) { "-$short" } else { '' }
        $groupName = $null
        if ($isGroupKind) {
            $groupName = if ($scope.AccessGroupName) {
                if ($suffix) { (Format-RBAC4AppSafeName -Value $scope.AccessGroupName -MaxLength ($script:RBAC4AppNameMaxLength.Group - $suffix.Length)) + $suffix }
                else { [string]$scope.AccessGroupName }
            }
            elseif ($declaresGroup -or $accessGroupType -eq 'M365Group') {
                Get-RBAC4AppScopeGroupName -Prefix $scope.GroupPrefix -DisplayName $displayName -Suffix $suffix -AppId $appId
            }
            else { throw 'RbacScope.AccessGroupName is required for a HybridMailEnabledSecurityGroup config.' }
        }
        $scopeName = Get-RBAC4AppManagementScopeName -DisplayName $displayName -Prefix $scope.ManagementScopePrefix -Name $scope.ManagementScopeName -Suffix $suffix -AppId $appId
        [pscustomobject]@{
            Role        = $scopeRole
            GroupName   = $groupName
            ScopeName   = $scopeName
            DnParameter = 'ScopeGroupDistinguishedName' + $short
        }
    }
    $contexts = @($contexts)

    # --- Management scope filter (static kinds are literals; Group is built from the DN parameter).
    $filterExpression = switch ($scope.ScopeKind) {
        'Group' { $null }
        'Recipients' {
            $addresses = @($scope.ScopeRecipients | Where-Object { $_ } | Sort-Object -Unique)
            if ($addresses.Count -eq 0) { throw 'RbacScope.ScopeRecipients is empty; cannot build the management scope filter.' }
            $parts = @($addresses | ForEach-Object { "PrimarySmtpAddress -eq '{0}'" -f ([string]$_).Replace("'", "''") })
            & $lit $(if ($parts.Count -eq 1) { $parts[0] } else { (@($parts | ForEach-Object { "($_)" }) -join ' -or ') })
        }
        'Tag' {
            $tagValue = if ($scope.ScopeTagValue) { [string]$scope.ScopeTagValue } else { $contexts[0].ScopeName }
            & $lit ("{0} -eq '{1}'" -f $scope.ScopeTagAttribute, $tagValue.Replace("'", "''"))
        }
        'Filter' {
            if (-not ([string]$scope.ScopeFilter).Trim()) { throw 'RbacScope.ScopeFilter is empty; cannot build the management scope filter.' }
            & $lit ([string]$scope.ScopeFilter).Trim()
        }
        default { throw "Unsupported RbacScope.ScopeKind '$($scope.ScopeKind)'." }
    }

    $sb = [System.Text.StringBuilder]::new()
    $add = { param([string] $line = '') [void]$sb.Append($line).Append("`r`n") }
    $auth = {
        param([string] $indent)
        if ($Authentication -eq 'Certificate') {
            & $add ('{0}ApplicationId         = $ApplicationId' -f $indent)
            & $add ('{0}TenantId              = $TenantId' -f $indent)
            & $add ('{0}CertificateThumbprint = $CertificateThumbprint' -f $indent)
        }
        else {
            & $add ('{0}ManagedIdentity = $true' -f $indent)
            & $add ('{0}TenantId        = $TenantId' -f $indent)
        }
    }

    # --- Header (line comments only; values are flattened to one line so they cannot leave the comment).
    & $add ('# Microsoft365DSC configuration - generated by EXORBACforAppManagement (config schema {0}).' -f (& $oneLine $full.SchemaVersion))
    & $add ('# Application : {0} (AppId {1}, service principal {2})' -f (& $oneLine $displayName), (& $oneLine $appId), (& $oneLine $app.SpObjectId))
    & $add ('# Roles       : {0}' -f (& $oneLine ($roles -join ', ')))
    & $add ('# Scope       : {0}' -f (& $oneLine $scope.ScopeKind))
    foreach ($property in $full.Metadata.PSObject.Properties) {
        if ([string]$property.Value) { & $add ('# {0,-11} : {1}' -f $property.Name, (& $oneLine $property.Value)) }
    }
    & $add '#'
    if ($Authentication -eq 'Certificate') {
        & $add '# Authentication: app registration + certificate (ApplicationId, TenantId, CertificateThumbprint parameters);'
        & $add '# the certificate must be in the certificate store of the machine that applies this. No secret is stored here.'
    }
    else {
        & $add '# Authentication: managed identity (ManagedIdentity + TenantId on every resource); no secret is stored here.'
    }
    & $add '# This is a second rendering of the RBAC4App config written next to it; it is not read by Invoke-RBAC4AppConfig.'
    foreach ($warning in $warnings) { & $add ('# NOTE: {0}' -f (& $oneLine $warning)) }
    foreach ($warning in @($full.Runtime.CollectedWarnings)) { & $add ('# WARNING: {0}' -f (& $oneLine $warning)) }
    & $add

    & $add "Configuration $ConfigurationName"
    & $add '{'
    & $add '    param'
    & $add '    ('
    $parameterBlocks = [System.Collections.Generic.List[string]]::new()
    $parameterBlock = {
        param([string] $name, [string] $default, [string] $comment)
        $lines = @()
        if ($comment) { $lines += "        # $comment" }
        $lines += if ($default) { '        [Parameter()]' } else { '        [Parameter(Mandatory = $true)]' }
        $lines += '        [System.String]'
        $lines += if ($default) { '        ${0} = {1}' -f $name, $default } else { '        ${0}' -f $name }
        $parameterBlocks.Add($lines -join "`r`n")
    }
    & $parameterBlock 'TenantId' $(if ([string]$app.TenantId) { & $lit $app.TenantId } else { '' }) $(if ($Authentication -eq 'Certificate') { 'Tenant to sign in to (for Exchange Online usually the tenant domain, e.g. contoso.onmicrosoft.com).' } else { 'Tenant the managed identity signs in to (for Exchange Online usually the tenant domain, e.g. contoso.onmicrosoft.com).' })
    if ($Authentication -eq 'Certificate') {
        & $parameterBlock 'ApplicationId' '' 'AppId of the app registration Microsoft365DSC signs in with (needs Exchange.ManageAsApp and an Exchange admin role).'
        & $parameterBlock 'CertificateThumbprint' '' 'Thumbprint of that app registration''s certificate in the local certificate store.'
    }
    if ($isGroupKind) {
        foreach ($context in $contexts) {
            $knownDn = if ($ScopeGroupDistinguishedName -and -not $separate) { & $lit $ScopeGroupDistinguishedName } else { '' }
            & $parameterBlock $context.DnParameter $knownDn ('Distinguished name of scope group {0} (Get-Recipient -Identity <group> | Select-Object DistinguishedName).' -f (& $oneLine $context.GroupName))
        }
    }
    & $add ($parameterBlocks -join (",`r`n`r`n"))
    & $add '    )'
    & $add
    & $add '    Import-DscResource -ModuleName Microsoft365DSC'
    & $add
    & $add '    Node localhost'
    & $add '    {'

    # --- Exchange Online service principal pointer (same naming as Register-EXOServicePrincipal).
    $spInstance = & $instance ("SP-$displayName-$appId")
    $spName = '{0}_SP' -f $displayName
    & $add ('        EXOServicePrincipal {0}' -f (& $lit $spInstance))
    & $add '        {'
    & $add ('            AppName         = {0}' -f (& $lit $spName))
    & $add ('            DisplayName     = {0}' -f (& $lit $spName))
    & $add ('            AppId           = {0}' -f (& $lit $appId))
    & $add ('            Identity        = {0}' -f (& $lit $app.SpObjectId))
    & $add "            Ensure          = 'Present'"
    & $auth '            '
    & $add '        }'

    foreach ($context in $contexts) {
        $groupInstance = $null
        if ($declaresGroup) {
            $groupInstance = & $instance ("Group-$($context.GroupName)")
            $groupMembers = @(@($scope.BootstrapMember) + @($scope.Members) | Where-Object { $_ } | Select-Object -Unique)
            $owners = @($scope.ManagedBy | Where-Object { $_ })
            & $add
            & $add ('        EXODistributionGroup {0}' -f (& $lit $groupInstance))
            & $add '        {'
            & $add ('            Identity                               = {0}' -f (& $lit $context.GroupName))
            & $add ('            Name                                   = {0}' -f (& $lit $context.GroupName))
            & $add ('            DisplayName                            = {0}' -f (& $lit $context.GroupName))
            & $add ('            Alias                                  = {0}' -f (& $lit $context.GroupName))
            & $add ('            Type                                   = {0}' -f (& $lit $(if ($accessGroupType -eq 'DistributionList') { 'Distribution' } else { 'Security' })))
            & $add ('            ManagedBy                              = {0}' -f (ConvertTo-RBAC4AppDscLiteral -Value $owners -AsList))
            & $add ('            Members                                = {0}' -f (ConvertTo-RBAC4AppDscLiteral -Value $groupMembers -AsList))
            & $add '            HiddenFromAddressListsEnabled          = $true'
            & $add '            RequireSenderAuthenticationEnabled     = $true'
            & $add ('            AcceptMessagesOnlyFromSendersOrMembers = {0}' -f (ConvertTo-RBAC4AppDscLiteral -Value $owners -AsList))
            & $add "            MemberJoinRestriction                  = 'Closed'"
            & $add "            MemberDepartRestriction                = 'Closed'"
            & $add "            Ensure                                 = 'Present'"
            & $auth '            '
            & $add '        }'
        }

        $scopeInstance = & $instance ("Scope-$($context.ScopeName)")
        $context | Add-Member -NotePropertyName ScopeInstance -NotePropertyValue $scopeInstance
        & $add
        & $add ('        EXOManagementScope {0}' -f (& $lit $scopeInstance))
        & $add '        {'
        & $add ('            Identity                   = {0}' -f (& $lit $context.ScopeName))
        & $add ('            Name                       = {0}' -f (& $lit $context.ScopeName))
        if ($isGroupKind) {
            # The DN is data at compile time too: quote-doubled inside the OPATH literal.
            & $add ('            RecipientRestrictionFilter = ("MemberOfGroup -eq ''{{0}}''" -f ${0}.Replace("''", "''''"))' -f $context.DnParameter)
        }
        else {
            & $add ('            RecipientRestrictionFilter = {0}' -f $filterExpression)
        }
        & $add "            Ensure                     = 'Present'"
        & $auth '            '
        if ($groupInstance) { & $add ('            DependsOn                  = {0}' -f (& $lit "[EXODistributionGroup]$groupInstance")) }
        & $add '        }'
    }

    foreach ($role in $roles) {
        $context = if ($separate) { $contexts | Where-Object { $_.Role -eq $role } | Select-Object -First 1 } else { $contexts[0] }
        $assignmentName = Get-RBAC4AppRoleAssignmentName -ShortRoleName $shortRoleMap[$role] -DisplayName $displayName -AppId $appId
        $dependsOn = @("[EXOServicePrincipal]$spInstance", "[EXOManagementScope]$($context.ScopeInstance)")
        & $add
        & $add ('        EXOManagementRoleAssignment {0}' -f (& $lit (& $instance "Assignment-$assignmentName")))
        & $add '        {'
        & $add ('            Name                = {0}' -f (& $lit $assignmentName))
        & $add ('            Role                = {0}' -f (& $lit $role))
        & $add ('            App                 = {0}' -f (& $lit $app.SpObjectId))
        & $add ('            CustomResourceScope = {0}' -f (& $lit $context.ScopeName))
        & $add "            Ensure              = 'Present'"
        & $auth '            '
        & $add ('            DependsOn           = {0}' -f (ConvertTo-RBAC4AppDscLiteral -Value $dependsOn -AsList))
        & $add '        }'
    }

    & $add '    }'
    & $add '}'

    [pscustomobject]@{
        ConfigurationName = $ConfigurationName
        Script            = $sb.ToString()
        Warnings          = @($warnings)
    }
}
