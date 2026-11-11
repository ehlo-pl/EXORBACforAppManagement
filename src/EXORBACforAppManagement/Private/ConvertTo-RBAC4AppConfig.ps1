function ConvertTo-RBAC4AppConfig {
    # Single builder for the RBAC4App handoff config object consumed by Invoke-RBAC4AppConfig
    # (serialized by ConvertTo-RBAC4AppYaml or ConvertTo-Json). Used by New-RBAC4AppConfig,
    # Get-RBAC4AppEntry, and Convert-ApplicationAccessPolicyToRBAC so the writers cannot drift from
    # each other or from $script:RBAC4AppConfigSchemaVersion.
    #
    # Only entries that are actually used are written: keys the selected ScopeKind/AssignmentScope
    # ignores, empty values unless explicitly supplied as overrides, and values equal to
    # $script:RBAC4AppConfigDefaults (restored on read by Complete-RBAC4AppConfig) are left out.
    # SchemaVersion, Application, Rbac.Roles, the full Metadata section (every key, empty when not
    # supplied) and the full Runtime section (GeneratedAt, OperatorUsername, OperatorMachineName,
    # CollectedErrors / CollectedWarnings - empty lists when nothing was collected) are always written.
    # The ConversionResult section is written, in full, only when -ConversionResult is supplied.
    [OutputType([pscustomobject])]
    param(
        [string] $TenantId = '',

        [Parameter(Mandatory)]
        [string] $AppId,

        [Parameter(Mandatory)]
        [string] $SpObjectId,

        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter(Mandatory)]
        [string[]] $Roles,

        [string] $ChangeReference = '',

        [Parameter(Mandatory)]
        [string] $AccessGroupType,

        [Parameter(Mandatory)]
        [string] $GroupPrefix,

        [string] $AccessGroupName = '',
        [string[]] $Members = @(),
        [bool] $MembersExplicit = $false,
        [string[]] $ManagedBy = @(),
        [string] $BootstrapMember = 'GraphAPI-Dummy',
        [bool] $BootstrapMemberExplicit = $false,

        [string] $ScopeKind = 'Group',
        [ValidateSet('ManagementScope', 'RecipientGroupScope')]
        [string] $AssignmentScope = 'ManagementScope',
        [string] $ManagementScopeName = '',
        [string] $ManagementScopePrefix = $script:RBAC4AppDefaultManagementScopePrefix,
        [string[]] $ScopeRecipients = @(),
        [string] $ScopeTagAttribute = 'CustomAttribute1',
        [string] $ScopeTagValue = '',
        [string] $ScopeFilter = '',
        [bool] $SeparateScopePerRole = $false,

        [string] $OwnerUsername = '',
        [string] $OwnerDisplayName = '',
        [string] $TechnicalContactUsername = '',
        [string] $TechnicalContactDisplayName = '',
        [string] $PCode = '',
        [string] $CmdbId = '',
        [string] $Description = '',
        [string] $NetworkAccessIP4Range = '',
        [string] $NetworkAccessIP6Range = '',
        [string] $NetworkAccessLocation = '',

        # Runtime section: errors/warnings collected by the writer while building this config.
        # Informational only; Invoke-RBAC4AppConfig never acts on them.
        [string[]] $CollectedErrors = @(),
        [string[]] $CollectedWarnings = @(),

        # ConversionResult section: the per-policy result of Convert-ApplicationAccessPolicyToRBAC
        # (its Warnings/Errors go to Runtime instead). Written only when supplied.
        [psobject] $ConversionResult = $null
    )

    $defaults = $script:RBAC4AppConfigDefaults
    $isGroupKind = $ScopeKind -eq 'Group'
    if (-not $isGroupKind) { $AssignmentScope = 'ManagementScope' }
    $members = @($Members | Where-Object { $_ })
    $owners = @($ManagedBy | Where-Object { $_ })

    $config = [ordered]@{
        SchemaVersion = $script:RBAC4AppConfigSchemaVersion
    }
    if ($TenantId) { $config.TenantId = $TenantId }
    $config.Application = [pscustomobject]@{
        AppId       = $AppId
        SpObjectId  = $SpObjectId
        DisplayName = $DisplayName
    }

    $config.Rbac = [pscustomobject]@{ Roles = @($Roles) }

    $scope = [ordered]@{}
    if ($ScopeKind -ne $defaults.ScopeKind) { $scope.ScopeKind = $ScopeKind }
    # Absent means RecipientGroupScope for the Group kind (schema 4.1) and ManagementScope otherwise.
    if ($isGroupKind -and $AssignmentScope -ne 'RecipientGroupScope') { $scope.AssignmentScope = $AssignmentScope }

    if ($isGroupKind) {
        if ($AccessGroupType -ne $defaults.AccessGroupType) { $scope.AccessGroupType = $AccessGroupType }
        # An explicit group name replaces the prefix entirely.
        if ($AccessGroupName) {
            $scope.AccessGroupName = $AccessGroupName
        }
        elseif ($GroupPrefix -and $GroupPrefix -ne (Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $AccessGroupType)) {
            $scope.GroupPrefix = $GroupPrefix
        }
        if (($members.Count -gt 0 -and (($members -join "`n") -ne ($defaults.Members -join "`n"))) -or
            ($MembersExplicit -and $members.Count -eq 0)) { $scope.Members = $members }
        if ($owners.Count -gt 0 -and (($owners -join "`n") -ne ($defaults.ManagedBy -join "`n"))) { $scope.ManagedBy = $owners }
        if (($BootstrapMember -and $BootstrapMember -ne $defaults.BootstrapMember) -or
            ($BootstrapMemberExplicit -and -not $BootstrapMember)) { $scope.BootstrapMember = $BootstrapMember }
        if ($SeparateScopePerRole) { $scope.SeparateScopePerRole = $true }
    }

    if ($AssignmentScope -eq 'ManagementScope') {
        if ($ManagementScopeName) {
            $scope.ManagementScopeName = $ManagementScopeName
        }
        elseif ($ManagementScopePrefix -and $ManagementScopePrefix -ne $script:RBAC4AppDefaultManagementScopePrefix) {
            $scope.ManagementScopePrefix = $ManagementScopePrefix
        }
    }

    switch ($ScopeKind) {
        'Recipients' {
            $recipients = @($ScopeRecipients | Where-Object { $_ })
            if ($recipients.Count -gt 0) { $scope.ScopeRecipients = $recipients }
        }
        'Tag' {
            if ($ScopeTagAttribute -and $ScopeTagAttribute -ne $defaults.ScopeTagAttribute) { $scope.ScopeTagAttribute = $ScopeTagAttribute }
            if ($ScopeTagValue) { $scope.ScopeTagValue = $ScopeTagValue }
        }
        'Filter' {
            if ($ScopeFilter) { $scope.ScopeFilter = $ScopeFilter }
        }
    }

    if ($scope.Count -gt 0) { $config.RbacScope = [pscustomobject]$scope }

    # Unlike the other sections, Metadata is never sparse: every key is always written (empty when
    # not supplied) so a generated file shows the full set of descriptive fields to fill in.
    $config.Metadata = [pscustomobject][ordered]@{
        ChangeReference             = [string]$ChangeReference
        OwnerUsername               = [string]$OwnerUsername
        OwnerDisplayName            = [string]$OwnerDisplayName
        TechnicalContactUsername    = [string]$TechnicalContactUsername
        TechnicalContactDisplayName = [string]$TechnicalContactDisplayName
        PCode                       = [string]$PCode
        CmdbId                      = [string]$CmdbId
        Description                 = [string]$Description
        NetworkAccessIP4Range       = [string]$NetworkAccessIP4Range
        NetworkAccessIP6Range       = [string]$NetworkAccessIP6Range
        NetworkAccessLocation       = [string]$NetworkAccessLocation
    }

    # Like Metadata, Runtime is never sparse: every key is always written (lists empty as []).
    # OperatorUsername/OperatorMachineName identify who generated the file and where.
    $operatorUser = [System.Environment]::UserName
    $operatorDomain = [System.Environment]::UserDomainName
    if ($operatorDomain -and $operatorDomain -ne [System.Environment]::MachineName -and $operatorUser) {
        $operatorUser = '{0}\{1}' -f $operatorDomain, $operatorUser
    }
    if ($ConversionResult) {
        $config.ConversionResult = [pscustomobject][ordered]@{
            AppId              = [string]$ConversionResult.AppId
            ResolvedDisplay    = [string]$ConversionResult.ResolvedDisplay
            AccessRight        = [string]$ConversionResult.AccessRight
            ScopeGroup         = [string]$ConversionResult.ScopeGroup
            DerivedRoles       = @($ConversionResult.DerivedRoles | Where-Object { $_ } | ForEach-Object { [string]$_ })
            SkippedPermissions = @($ConversionResult.SkippedPermissions | Where-Object { $_ } | ForEach-Object { [string]$_ })
            ConfigPath         = [string]$ConversionResult.ConfigPath
        }
    }

    $config.Runtime = [pscustomobject][ordered]@{
        GeneratedAt         = (Get-Date).ToUniversalTime().ToString('o')
        OperatorUsername    = [string]$operatorUser
        OperatorMachineName = [string][System.Environment]::MachineName
        CollectedErrors   = @($CollectedErrors | Where-Object { $_ } | ForEach-Object { [string]$_ })
        CollectedWarnings = @($CollectedWarnings | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }

    [pscustomobject]$config
}
