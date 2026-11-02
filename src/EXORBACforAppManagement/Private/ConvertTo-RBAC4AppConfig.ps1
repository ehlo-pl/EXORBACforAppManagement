function ConvertTo-RBAC4AppConfig {
    # Single builder for the RBAC4App handoff config object consumed by Invoke-RBAC4AppConfig
    # (serialized by ConvertTo-RBAC4AppYaml or ConvertTo-Json). Used by New-RBAC4AppConfig,
    # Get-RBAC4AppEntry, and Convert-ApplicationAccessPolicyToRBAC so the writers cannot drift from
    # each other or from $script:RBAC4AppConfigSchemaVersion.
    #
    # Only entries that are actually used are written: keys the selected ScopeKind/AssignmentScope
    # ignores, empty values, and values equal to $script:RBAC4AppConfigDefaults (restored on read by
    # Complete-RBAC4AppConfig) are left out. SchemaVersion, GeneratedAt, Application, and Rbac.Roles
    # are always written.
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
        [string[]] $ManagedBy = @(),
        [string] $BootstrapMember = 'GraphAPI-Dummy',

        [string] $ScopeKind = 'Group',
        [ValidateSet('ManagementScope', 'RecipientGroupScope')]
        [string] $AssignmentScope = 'ManagementScope',
        [string] $ManagementScopeName = '',
        [string] $ManagementScopePrefix = $script:RBAC4AppDefaultManagementScopePrefix,
        [string[]] $ScopeRecipients = @(),
        [string] $ScopeTagAttribute = 'CustomAttribute1',
        [string] $ScopeTagValue = '',
        [string] $ScopeFilter = '',
        [bool] $SeparateScopePerRole = $false
    )

    $defaults = $script:RBAC4AppConfigDefaults
    $isGroupKind = $ScopeKind -eq 'Group'
    if (-not $isGroupKind) { $AssignmentScope = 'ManagementScope' }
    $members = @($Members | Where-Object { $_ })
    $owners = @($ManagedBy | Where-Object { $_ })

    $config = [ordered]@{
        SchemaVersion = $script:RBAC4AppConfigSchemaVersion
        GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($TenantId) { $config.TenantId = $TenantId }
    $config.Application = [pscustomobject]@{
        AppId       = $AppId
        SpObjectId  = $SpObjectId
        DisplayName = $DisplayName
    }

    $rbac = [ordered]@{ Roles = @($Roles) }
    if ($ChangeReference) { $rbac.ChangeReference = $ChangeReference }
    $config.Rbac = [pscustomobject]$rbac

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
        if ($members.Count -gt 0 -and (($members -join "`n") -ne ($defaults.Members -join "`n"))) { $scope.Members = $members }
        if ($owners.Count -gt 0 -and (($owners -join "`n") -ne ($defaults.ManagedBy -join "`n"))) { $scope.ManagedBy = $owners }
        if ($BootstrapMember -and $BootstrapMember -ne $defaults.BootstrapMember) { $scope.BootstrapMember = $BootstrapMember }
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

    [pscustomobject]$config
}
