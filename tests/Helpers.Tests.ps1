#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
}

Describe 'Format-RBAC4AppSafeName' {
    It 'strips characters that are not letters, digits, or dash' {
        InModuleScope EXORBACforAppManagement {
            Format-RBAC4AppSafeName -Value 'Um365RAo1-Contoso Mail App!@#' | Should -Be 'Um365RAo1-ContosoMailApp'
        }
    }

    It 'caps the result at the requested length' {
        InModuleScope EXORBACforAppManagement {
            (Format-RBAC4AppSafeName -Value ('a' * 100) -MaxLength 63).Length | Should -Be 63
        }
    }

    It 'defaults the cap to 63' {
        InModuleScope EXORBACforAppManagement {
            (Format-RBAC4AppSafeName -Value ('b' * 200)).Length | Should -Be 63
        }
    }
}

Describe 'ConvertTo-RBAC4AppRoleName' {
    It 'maps a known short name to the Application role' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRoleName -Role 'Mail.Send' | Should -Be 'Application Mail.Send'
        }
    }

    It 'passes through an already-normalized role unchanged' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRoleName -Role 'Application Calendars.Read' | Should -Be 'Application Calendars.Read'
        }
    }

    It 'passes through an unknown role unchanged' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRoleName -Role 'Totally.Unknown' | Should -Be 'Totally.Unknown'
        }
    }
}

Describe 'Get-RBAC4AppDefaultGroupPrefix' {
    It 'returns the type-specific default prefix' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType DistributionList | Should -Be 'UDLRAo1P'
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType MailEnabledSecurityGroup | Should -Be 'USRAo1P'
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType M365Group | Should -Be 'Um365RAo1P'
        }
    }
}

Describe 'Generated-name helpers' {
    It 'builds the scope group name with the Group limit, keeping the role suffix' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppScopeGroupName -Prefix 'UDLRAo1P' -DisplayName 'Contoso Mail App' | Should -Be 'UDLRAo1P-ContosoMailApp'
            $n = Get-RBAC4AppScopeGroupName -Prefix 'P' -DisplayName ('x' * 100) -Suffix '-MailSend'
            $n.Length | Should -Be 63
            $n | Should -BeLike '*-MailSend'
        }
    }

    It 'builds the role assignment name capped at the RoleAssignment limit' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppRoleAssignmentName -ShortRoleName 'AppMailSend' -DisplayName 'Contoso App' | Should -Be 'AppMailSend-ContosoApp'
            (Get-RBAC4AppRoleAssignmentName -ShortRoleName 'AppMailSend' -DisplayName ('y' * 100)).Length | Should -Be 63
        }
    }

    It 'builds the management scope name with the 64-char limit and keeps the suffix' {
        InModuleScope EXORBACforAppManagement {
            (Get-RBAC4AppManagementScopeName -DisplayName ('z' * 100) -Suffix '-MailSend').Length | Should -Be 64
            Get-RBAC4AppManagementScopeName -DisplayName 'Contoso' -Name 'Explicit_Scope' | Should -Be 'Explicit_Scope'
        }
    }
}
