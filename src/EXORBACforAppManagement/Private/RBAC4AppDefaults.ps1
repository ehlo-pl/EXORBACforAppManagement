# Module-wide defaults and Exchange name-length limits shared by every function that derives
# object names, so New-/Set-/Remove-/Test-RBAC4AppEntry and the config paths cannot drift apart.
# Dot-sourced by the module loader, so these live in module (script) scope.

$script:RBAC4AppDefaultManagementScopePrefix = 'MSRAo1P'

# Maximum generated-name lengths per Exchange object type. Group and role-assignment names are
# held at 63 (alias-safe), management scope names at 64; changing a value renames any generated
# object whose name was previously truncated.
$script:RBAC4AppNameMaxLength = @{
    Default        = 63
    Group          = 63
    RoleAssignment = 63
    ManagementScope = 64
}

function Get-RBAC4AppDefaultGroupPrefix {
    # Default scope-group name prefix for an -AccessGroupType.
    param(
        [Parameter(Mandatory)]
        [string] $AccessGroupType
    )

    switch ($AccessGroupType) {
        'DistributionList'         { 'UDLRAo1P' }
        'MailEnabledSecurityGroup' { 'USRAo1P' }
        default                    { 'Um365RAo1P' }
    }
}

# Version of the RBAC4App config file schema. New-RBAC4AppConfig and
# Convert-ApplicationAccessPolicyToRBAC write it (via ConvertTo-RBAC4AppConfig);
# Invoke-RBAC4AppConfig accepts every version listed as supported ('3.0' is read as ScopeKind Group;
# '3.0' and '4.0' have no RbacScope.AssignmentScope and are read as ManagementScope).
$script:RBAC4AppConfigSchemaVersion = '4.1'
$script:RBAC4AppConfigSupportedSchemaVersions = @('3.0', '4.0', '4.1')

# Values a config file falls back to when a key is absent. ConvertTo-RBAC4AppConfig omits any key
# equal to its default (or empty, or unused by the selected ScopeKind/AssignmentScope), and
# Complete-RBAC4AppConfig fills them back in on read, so both sides must use this one table.
# GroupPrefix defaults per AccessGroupType (Get-RBAC4AppDefaultGroupPrefix), ManagementScopePrefix to
# $script:RBAC4AppDefaultManagementScopePrefix, and AssignmentScope per schema version (see
# Complete-RBAC4AppConfig).
$script:RBAC4AppConfigDefaults = @{
    AccessGroupType   = 'DistributionList'
    Members           = @('GraphAPI-Dummy')
    ManagedBy         = @('GraphAPI-Dummy-owner')
    BootstrapMember   = 'GraphAPI-Dummy'
    ScopeKind         = 'Group'
    ScopeTagAttribute = 'CustomAttribute1'
}
