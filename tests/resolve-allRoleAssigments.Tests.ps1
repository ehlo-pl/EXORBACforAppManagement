BeforeAll {
    $script:reportPath = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'scripts') 'resolve-allRoleAssigments.ps1'
    $global:ReportTestAssignment = [pscustomobject]@{
        Name = 'AppMailSend-Demo'
        Role = 'Application Mail.Send'
        RoleAssigneeName = 'Demo_SP'
        RoleAssigneeType = 'ServicePrincipal'
        AssignmentMethod = 'Direct'
        EffectiveUserName = $null
        App = $null
        CustomResourceScope = 'DemoScope_11111111-2222-3333-4444-555555555555'
        RecipientWriteScope = 'Group'
        Enabled = $true
    }
    $global:ReportTestPrincipal = [pscustomobject]@{
        DisplayName = 'Demo_SP'
        AppId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        ObjectId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    }

    function global:Get-ManagementRoleAssignment {
        [CmdletBinding()]
        param([string]$Role, [string]$Identity)
        $global:ReportTestAssignment
    }
    function global:Get-ServicePrincipal {
        [CmdletBinding()]
        param([string]$Identity)
        $global:ReportTestPrincipal
    }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Get-DistributionGroup {
        [CmdletBinding()]
        param([string]$Identity)
        if ($Identity -eq 'DemoScope') {
            [pscustomobject]@{ RecipientTypeDetails = 'MailUniversalDistributionGroup' }
        }
    }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementScope { [CmdletBinding()] param([string]$Identity) }
    function global:Get-Recipient {
        [CmdletBinding()]
        param([string]$Identity, [string]$RecipientPreviewFilter, $ResultSize)
        if ($Identity -eq 'DemoScope') {
            [pscustomobject]@{
                PrimarySmtpAddress = 'demo@contoso.com'
                RecipientTypeDetails = 'MailUniversalDistributionGroup'
            }
        }
    }
    function global:Get-MgServicePrincipal {
        [CmdletBinding()]
        param([string]$Filter, [switch]$All, [string]$ServicePrincipalId)
        if ($Filter -ne "appId eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'") {
            throw 'Graph lookup must use the AppId resolved by Get-RBAC4AppEntry.'
        }
        [pscustomobject]@{
            DisplayName = 'Demo'
            AppId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            ServicePrincipalType = 'Application'
            AdditionalProperties = @{ createdDateTime = '2026-01-01T00:00:00Z' }
        }
    }
    function global:Get-ApplicationAccessPolicy {
        [CmdletBinding()]
        param([string]$AppId)
        [pscustomobject]@{
            AppId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            ScopeName = 'DemoPolicy'
            Identity = 'policy1'
            ScopeIdentity = 'scope1'
            AccessRight = 'RestrictAccess'
        }
    }
    function global:Export-Excel {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)]$InputObject,
            $Path,
            $Title,
            $TableName,
            $WorksheetName
        )
        process {}
    }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($name in @(
        'Get-ManagementRoleAssignment', 'Get-ServicePrincipal', 'Get-UnifiedGroup',
        'Get-UnifiedGroupLinks', 'Get-DistributionGroup', 'Get-DistributionGroupMember',
        'Get-ManagementScope', 'Get-Recipient', 'Get-MgServicePrincipal',
        'Get-ApplicationAccessPolicy', 'Export-Excel'
    )) {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable ReportTestAssignment, ReportTestPrincipal -Scope Global -ErrorAction SilentlyContinue
}

Describe 'resolve-allRoleAssigments report' {
    It 'uses the module-resolved AppId and group identity when EffectiveUserName is empty' {
        $rows = @(& $script:reportPath)

        $rows.Count | Should -Be 1
        $rows[0].EffectiveUserName | Should -BeNullOrEmpty
        $rows[0].RAAppID | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $rows[0].EffectiveScopeAddress | Should -Be 'demo@contoso.com'
        $rows[0].EffectiveScopeType | Should -Be 'MailUniversalDistributionGroup'
        $rows[0].RowType | Should -Be 'RBAC + Policy'
        $rows[0].LookupStatus | Should -Be 'OK'
    }
}
