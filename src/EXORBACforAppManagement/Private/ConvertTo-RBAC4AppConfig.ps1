function ConvertTo-RBAC4AppConfig {
    # Single builder for the RBAC4App handoff config object consumed by Invoke-RBAC4AppConfig
    # (serialized by ConvertTo-RBAC4AppYaml or ConvertTo-Json). Used by New-RBAC4AppConfig and
    # Convert-ApplicationAccessPolicyToRBAC so the two writers cannot drift from each other or
    # from $script:RBAC4AppConfigSchemaVersion.
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
        [string] $ManagementScopeName = '',
        [string] $ManagementScopePrefix = $script:RBAC4AppDefaultManagementScopePrefix,
        [string[]] $ScopeRecipients = @(),
        [string] $ScopeTagAttribute = 'CustomAttribute1',
        [string] $ScopeTagValue = '',
        [string] $ScopeFilter = '',
        [bool] $SeparateScopePerRole = $false
    )

    [pscustomobject]@{
        SchemaVersion = $script:RBAC4AppConfigSchemaVersion
        GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
        TenantId      = $TenantId
        Application   = [pscustomobject]@{
            AppId       = $AppId
            SpObjectId  = $SpObjectId
            DisplayName = $DisplayName
        }
        Rbac          = [pscustomobject]@{
            Roles           = @($Roles)
            ChangeReference = $ChangeReference
        }
        RbacScope     = [pscustomobject]@{
            AccessGroupType       = $AccessGroupType
            GroupPrefix           = $GroupPrefix
            AccessGroupName       = $AccessGroupName
            Members               = @($Members)
            ManagedBy             = @($ManagedBy)
            BootstrapMember       = $BootstrapMember
            ScopeKind             = $ScopeKind
            ManagementScopeName   = $ManagementScopeName
            ManagementScopePrefix = $ManagementScopePrefix
            ScopeRecipients       = @($ScopeRecipients | Where-Object { $_ })
            ScopeTagAttribute     = $ScopeTagAttribute
            ScopeTagValue         = $ScopeTagValue
            ScopeFilter           = $ScopeFilter
            SeparateScopePerRole  = $SeparateScopePerRole
        }
    }
}
