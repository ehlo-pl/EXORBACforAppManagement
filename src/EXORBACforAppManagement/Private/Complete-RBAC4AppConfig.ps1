function Complete-RBAC4AppConfig {
    # Counterpart of ConvertTo-RBAC4AppConfig's pruning: takes a parsed config (YAML or JSON, any
    # supported schema version) and returns a full config object with every key present, filling
    # absent values from $script:RBAC4AppConfigDefaults. Invoke-RBAC4AppConfig and
    # ConvertFrom-RBAC4AppYaml both go through it, so a key left out of a file always means its
    # default while explicitly empty Members and BootstrapMember values remain overrides. An absent
    # AssignmentScope means RecipientGroupScope for a ScopeKind Group config of schema 4.1 or later,
    # and ManagementScope otherwise ('3.0'/'4.0' predate direct group binding).
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [psobject] $Config
    )

    $defaults = $script:RBAC4AppConfigDefaults
    $app = $Config.Application
    $rbac = $Config.Rbac
    $scope = $Config.RbacScope
    $metadata = $Config.Metadata

    $list = { param($Value) @($Value | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [string]$_ }) }
    $text = { param($Value, $Default) if ([string]$Value) { [string]$Value } else { $Default } }

    $schemaVersion = [string]$Config.SchemaVersion
    $scopeKind = & $text $scope.ScopeKind $defaults.ScopeKind
    $accessGroupType = & $text $scope.AccessGroupType $defaults.AccessGroupType
    $members = & $list $scope.Members
    $owners = & $list $scope.ManagedBy
    $membersSpecified = $false
    $bootstrapMemberSpecified = $false
    if ($scope) {
        $membersSpecified = $null -ne $scope.PSObject.Properties['Members']
        $bootstrapMemberSpecified = $null -ne $scope.PSObject.Properties['BootstrapMember']
    }
    $bootstrapMember = if ($bootstrapMemberSpecified) { [string]$scope.BootstrapMember } else { $defaults.BootstrapMember }
    $defaultAssignmentScope = if ($scopeKind -eq 'Group' -and $schemaVersion -notin @('3.0', '4.0')) { 'RecipientGroupScope' } else { 'ManagementScope' }

    [pscustomobject]@{
        SchemaVersion = $schemaVersion
        GeneratedAt   = [string]$Config.GeneratedAt
        TenantId      = [string]$Config.TenantId
        Application   = [pscustomobject]@{
            AppId       = [string]$app.AppId
            SpObjectId  = [string]$app.SpObjectId
            DisplayName = [string]$app.DisplayName
        }
        Rbac          = [pscustomobject]@{
            Roles = & $list $rbac.Roles
        }
        RbacScope     = [pscustomobject]@{
            AccessGroupType       = $accessGroupType
            GroupPrefix           = & $text $scope.GroupPrefix (Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $accessGroupType)
            AccessGroupName       = [string]$scope.AccessGroupName
            Members               = if ($membersSpecified) { $members } else { @($defaults.Members) }
            ManagedBy             = if ($owners.Count -gt 0) { $owners } else { @($defaults.ManagedBy) }
            BootstrapMember       = $bootstrapMember
            ScopeKind             = $scopeKind
            AssignmentScope       = & $text $scope.AssignmentScope $defaultAssignmentScope
            ManagementScopeName   = [string]$scope.ManagementScopeName
            ManagementScopePrefix = & $text $scope.ManagementScopePrefix $script:RBAC4AppDefaultManagementScopePrefix
            ScopeRecipients       = & $list $scope.ScopeRecipients
            ScopeTagAttribute     = & $text $scope.ScopeTagAttribute $defaults.ScopeTagAttribute
            ScopeTagValue         = [string]$scope.ScopeTagValue
            ScopeFilter           = [string]$scope.ScopeFilter
            SeparateScopePerRole  = ([string]$scope.SeparateScopePerRole -eq 'true')
        }
        Metadata      = [pscustomobject]@{
            ChangeReference             = if ([string]$metadata.ChangeReference) { [string]$metadata.ChangeReference } else { [string]$rbac.ChangeReference }
            OwnerUsername               = [string]$metadata.OwnerUsername
            OwnerDisplayName            = [string]$metadata.OwnerDisplayName
            TechnicalContactUsername    = [string]$metadata.TechnicalContactUsername
            TechnicalContactDisplayName = [string]$metadata.TechnicalContactDisplayName
            PCode                       = [string]$metadata.PCode
            CmdbId                      = [string]$metadata.CmdbId
            Description                 = [string]$metadata.Description
            NetworkAccessIPRange        = [string]$metadata.NetworkAccessIPRange
            NetworkAccessLocation       = [string]$metadata.NetworkAccessLocation
        }
    }
}
