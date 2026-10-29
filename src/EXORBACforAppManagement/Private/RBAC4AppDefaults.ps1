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
