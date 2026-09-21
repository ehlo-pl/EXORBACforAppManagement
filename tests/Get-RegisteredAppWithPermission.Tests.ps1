#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Get-RegisteredAppWithPermission is now a thin deprecated wrapper around
# Get-RBAC4AppEntry -ByApplication -ScopeType All; see Get-RBAC4AppEntry.Tests.ps1 for the
# behavioral coverage of the app-centric view itself.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
}

Describe 'Get-RegisteredAppWithPermission (deprecated wrapper)' {
    It 'warns and delegates to Get-RBAC4AppEntry -ByApplication -ScopeType All' {
        Mock -ModuleName EXORBACforAppManagement Get-RBAC4AppEntry { [pscustomobject]@{ DisplayName = 'Contoso' } }

        $warnings = $null
        $r = Get-RegisteredAppWithPermission -WarningVariable warnings -WarningAction SilentlyContinue

        $r.DisplayName | Should -Be 'Contoso'
        ($warnings -join ';') | Should -Match 'deprecated'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-RBAC4AppEntry -Times 1 -ParameterFilter {
            $ByApplication -eq $true -and $ScopeType -eq 'All'
        }
    }

    It 'forwards -Role and -Enabled' {
        Mock -ModuleName EXORBACforAppManagement Get-RBAC4AppEntry { }

        Get-RegisteredAppWithPermission -Role 'Mail.Send' -Enabled $true -WarningAction SilentlyContinue

        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-RBAC4AppEntry -Times 1 -ParameterFilter {
            $Role -eq 'Mail.Send' -and $Enabled -eq $true -and $ByApplication -eq $true -and $ScopeType -eq 'All'
        }
    }
}
