# Module-wide defaults and Exchange name-length limits shared by every function that derives
# object names, so New-/Set-/Remove-/Test-RBAC4AppEntry and the config paths cannot drift apart.
# Dot-sourced by the module loader, so these live in module (script) scope.

$script:RBAC4AppDefaultManagementScopePrefix = 'MSRAo1P'

# RecipientTypeDetails values accepted for -AccessGroupType HybridMailEnabledSecurityGroup
# (reference-only, on-prem/hybrid-synced). Any other recipient (a mailbox, a plain distribution group,
# ...) is rejected so a MemberOfGroup scope is never bound to the wrong object.
$script:RBAC4AppSecurityGroupRecipientTypes = @('MailUniversalSecurityGroup', 'MailNonUniversalGroup')

# -AccessGroupType values. CloudMailEnabledSecurityGroup (default) and DistributionList are
# Exchange-Online-mastered groups created and managed with the *-DistributionGroup cmdlets;
# M365Group with the *-UnifiedGroup cmdlets; HybridMailEnabledSecurityGroup is reference-only
# (never created, re-membered, or send-restricted). 'MailEnabledSecurityGroup' is the pre-0.9.0 name
# of the hybrid type, still accepted on input (parameters and config files) and normalized by
# ConvertTo-RBAC4AppAccessGroupType; every writer emits the new name.
$script:RBAC4AppAccessGroupTypes = @('CloudMailEnabledSecurityGroup', 'DistributionList', 'M365Group', 'HybridMailEnabledSecurityGroup')
$script:RBAC4AppDistributionGroupTypes = @('CloudMailEnabledSecurityGroup', 'DistributionList')
$script:RBAC4AppCreatableGroupTypes = @('CloudMailEnabledSecurityGroup', 'DistributionList', 'M365Group')
$script:RBAC4AppDefaultOwner = 'GraphAPI-Dummy-owner'

function ConvertTo-RBAC4AppAccessGroupType {
    # Normalizes an -AccessGroupType value: maps the legacy alias 'MailEnabledSecurityGroup' to
    # 'HybridMailEnabledSecurityGroup' and returns the canonical casing of a known value. An empty
    # value is returned as-is (callers apply their own default); an unknown one is returned unchanged
    # for the caller to reject.
    param(
        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $AccessGroupType
    )

    if (-not $AccessGroupType) { return $AccessGroupType }
    if ($AccessGroupType -eq 'MailEnabledSecurityGroup') { return 'HybridMailEnabledSecurityGroup' }
    $known = $script:RBAC4AppAccessGroupTypes | Where-Object { $_ -eq $AccessGroupType } | Select-Object -First 1
    if ($known) { return [string]$known }
    return $AccessGroupType
}

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
        'CloudMailEnabledSecurityGroup'  { 'USRACo1P' }
        'DistributionList'               { 'UDLRAo1P' }
        'HybridMailEnabledSecurityGroup' { 'USRAHo1P' }
        'MailEnabledSecurityGroup'       { 'USRAHo1P' }
        default                          { 'Um365RAo1P' }
    }
}

# Version of the RBAC4App config file schema. Every writer emits it (via ConvertTo-RBAC4AppConfig)
# and Invoke-RBAC4AppConfig accepts only this version - no compatibility with earlier ones.
$script:RBAC4AppConfigSchemaVersion = '4.4'
# The same holds for the New-RBAC4AppConfig -Repository state file and
# utils/Export-RBAC4AppStateReport.ps1: a file that names another SchemaVersion is refused / skipped.
# There is no reading of older layouts (legacy keys, version-dependent defaults) anywhere.

# Values a config file falls back to when a key is absent. ConvertTo-RBAC4AppConfig omits any key
# equal to its default (or empty unless explicitly overridden, or unused by the selected
# ScopeKind/AssignmentScope), and Complete-RBAC4AppConfig fills absent keys back in on read, so both
# sides must use this one table.
# GroupPrefix defaults per AccessGroupType (Get-RBAC4AppDefaultGroupPrefix), ManagementScopePrefix to
# $script:RBAC4AppDefaultManagementScopePrefix, and AssignmentScope per schema version (see
# Complete-RBAC4AppConfig).
$script:RBAC4AppConfigDefaults = @{
    AccessGroupType   = 'CloudMailEnabledSecurityGroup'
    Members           = @('GraphAPI-Dummy')
    ManagedBy         = @('GraphAPI-Dummy-owner')
    BootstrapMember   = 'GraphAPI-Dummy'
    ScopeKind         = 'Group'
    ScopeTagAttribute = 'CustomAttribute1'
}
