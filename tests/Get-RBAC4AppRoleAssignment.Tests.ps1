#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-ManagementRoleAssignment { [CmdletBinding()] param([string]$Role, [string]$Identity) }
    function global:Get-ServicePrincipal { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Get-DistributionGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }

    $script:Assignments = @(
        [pscustomobject]@{
            Name = 'AppMailSend-Contoso'
            Role = 'Application Mail.Send'
            RoleAssigneeName = 'Contoso_SP'
            RoleAssigneeType = 'ServicePrincipal'
            AssignmentMethod = 'Direct'
            EffectiveUserName = 'NT AUTHORITY\SYSTEM (Contoso_SP)'
            App = 'Contoso_SP'
            CustomResourceScope = 'UDLRAo1P-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'
            RecipientWriteScope = 'Group'
            RecipientReadScope = 'None'
        }
        [pscustomobject]@{
            Name = 'AppMailSend-Helpdesk'
            Role = 'Application Mail.Send'
            RoleAssigneeName = 'Helpdesk'
            RoleAssigneeType = 'RoleGroup'
        }
        [pscustomobject]@{
            Name = 'Mail Recipients-Contoso'
            Role = 'Mail Recipients'
            RoleAssigneeName = 'Contoso_SP'
            RoleAssigneeType = 'ServicePrincipal'
        }
    )
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($name in 'Get-ManagementRoleAssignment','Get-ServicePrincipal','Get-UnifiedGroup','Get-UnifiedGroupLinks','Get-DistributionGroup','Get-DistributionGroupMember') {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RBAC4AppRoleAssignment' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:Assignments }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' })
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1P-Contoso') {
                [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @([pscustomobject]@{ PrimarySmtpAddress = 'member@contoso.com'; Name = 'member' })
        }
    }

    It 'filters application roles to service principals and resolves the application and scope recipients' {
        $result = @(Get-RBAC4AppRoleAssignment)

        $result.Count | Should -Be 1
        $result[0].Name | Should -Be 'AppMailSend-Contoso'
        $result[0].RoleAssigneeName | Should -Be 'Contoso'
        $result[0].App | Should -Be 'Contoso'
        $result[0].CustomResourceScope | Should -Be @('member@contoso.com')
        $result[0].AssignmentMethod | Should -Be 'Direct'
        $result[0].EffectiveUserName | Should -Be 'NT AUTHORITY\SYSTEM (Contoso_SP)'
        $result[0].RecipientWriteScope | Should -Be 'Group'
        $result[0].RecipientReadScope | Should -Be 'None'
    }
}
