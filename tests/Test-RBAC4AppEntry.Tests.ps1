#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI
    # (where Microsoft.Graph / ExchangeOnlineManagement are not installed). Parameters the
    # code passes must be declared so the mock can bind and filter on them.
    function global:Get-MgContext { [CmdletBinding()] param() }
    function global:Get-MgServicePrincipal { [CmdletBinding()] param([string]$Filter, [string]$ServicePrincipalId) }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ServicePrincipal { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementRoleAssignment { [CmdletBinding()] param([string]$Role, [string]$Identity) }
    function global:Get-Recipient { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Get-DistributionGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }

    $script:Sp = [pscustomobject]@{ DisplayName = 'Contoso'; AppId = '11111111-1111-1111-1111-111111111111'; Id = '22222222-2222-2222-2222-222222222222' }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-MgContext','Get-MgServicePrincipal','Get-UnifiedGroup','Get-ServicePrincipal','Get-ManagementRoleAssignment','Get-Recipient','Get-UnifiedGroupLinks','Get-DistributionGroup','Get-DistributionGroupMember') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Test-RBAC4AppEntry' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { $script:Sp }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Contoso'; Identity = 'Um365RAo1-Contoso' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111' }) }
        # Non-parameter-filtered so individual It blocks can fully override it (a parameter-filtered
        # mock would otherwise keep matching ahead of a plain override).
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            if ($Identity -eq 'AppMailSend-Contoso') {
                [pscustomobject]@{ Name = $Identity; Role = 'Application Mail.Send'; Identity = $Identity }
            }
        }
    }

    It 'reports IsValid when every component is present' {
        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso'

        $r.IsValid | Should -BeTrue
        $r.ServicePrincipalExists | Should -BeTrue
        $r.UnifiedGroupExists | Should -BeTrue
        $r.ExoServicePrincipalExists | Should -BeTrue
        $r.UnifiedGroupName | Should -Be 'Um365RAo1-Contoso'
        $r.ExoServicePrincipalName | Should -Be 'Contoso_SP'
        $r.RoleAssignmentsFound | Should -Be @('AppMailSend-Contoso')
        $r.RoleAssignmentsMissing | Should -BeNullOrEmpty
        $r.Missing | Should -BeNullOrEmpty
    }

    It 'normalizes a short role name to its full Application role' {
        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send'
        $r.RolesExpected | Should -Be @('Application Mail.Send')
        $r.IsValid | Should -BeTrue
    }

    It 'flags a missing Unified Group' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso'
        $r.UnifiedGroupExists | Should -BeFalse
        $r.IsValid | Should -BeFalse
        $r.Missing | Should -Contain "M365Group 'Um365RAo1-Contoso'"
    }

    It 'flags a missing Exchange Online service principal' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso'
        $r.ExoServicePrincipalExists | Should -BeFalse
        $r.IsValid | Should -BeFalse
        $r.Missing | Should -Contain "Exchange Online service principal 'Contoso_SP'"
    }

    It 'flags a missing role assignment' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso'
        $r.RoleAssignmentsMissing | Should -Be @('AppMailSend-Contoso')
        $r.RoleAssignmentsFound | Should -BeNullOrEmpty
        $r.IsValid | Should -BeFalse
    }

    It 'does not count an assignment whose role does not match' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = $Identity; Role = 'Application Calendars.Read'; Identity = $Identity }
        }

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso'
        $r.RoleAssignmentsMissing | Should -Be @('AppMailSend-Contoso')
        $r.IsValid | Should -BeFalse
    }

    It 'verifies group membership when -Members is supplied' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' } }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @([pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' }) }

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso' -Members 'shared@contoso.com'
        $r.MembersPresent | Should -Be @('shared@contoso.com')
        $r.MembersMissing | Should -BeNullOrEmpty
        $r.IsValid | Should -BeTrue
    }

    It 'flags a member that is not in the group' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'missing@contoso.com'; Name = 'missing' } }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso' -Members 'missing@contoso.com'
        $r.MembersMissing | Should -Be @('missing@contoso.com')
        $r.IsValid | Should -BeFalse
        $r.Missing | Should -Contain "Group member 'missing@contoso.com'"
    }

    It 'records an error and is not valid when the service principal cannot be resolved' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { @() }

        $r = Test-RBAC4AppEntry -AppId '33333333-3333-3333-3333-333333333333'
        $r.ServicePrincipalExists | Should -BeFalse
        $r.IsValid | Should -BeFalse
        $r.Errors.Count | Should -BeGreaterThan 0
    }
}

Describe 'Test-RBAC4AppEntry -AccessGroupType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { $script:Sp }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111' }) }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            if ($Identity -eq 'AppMailSend-Contoso') { [pscustomobject]@{ Name = $Identity; Role = 'Application Mail.Send' } }
        }
    }

    It 'DistributionList: reads existence via Get-DistributionGroup and membership via Get-DistributionGroupMember' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Contoso'; Identity = 'Um365RAo1-Contoso' } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @([pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' }) }

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType DistributionList -Members 'shared@contoso.com'

        $r.AccessGroupType | Should -Be 'DistributionList'
        $r.UnifiedGroupExists | Should -BeTrue
        $r.MembersPresent | Should -Be @('shared@contoso.com')
        $r.IsValid | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-DistributionGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-DistributionGroupMember -Times 1
    }

    It 'MailEnabledSecurityGroup: reads existence via Get-Recipient and flags the named group when missing' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { }   # group not found

        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope'

        $r.UnifiedGroupName | Should -Be 'OnPrem-Scope'
        $r.UnifiedGroupExists | Should -BeFalse
        $r.Missing | Should -Contain "MailEnabledSecurityGroup 'OnPrem-Scope'"
    }

    It 'MailEnabledSecurityGroup: errors when -AccessGroupName is omitted' {
        $r = Test-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup
        ($r.Errors -join ';') | Should -Match 'AccessGroupName is required'
    }
}
