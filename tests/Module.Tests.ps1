#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1'
    Import-Module $script:ManifestPath -Force
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
}

Describe 'EXORBACforAppManagement module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports exactly the thirteen public functions' {
        $exported = (Get-Command -Module EXORBACforAppManagement -CommandType Function).Name | Sort-Object
        $exported | Should -Be @('Convert-ApplicationAccessPolicyToRBAC', 'Get-RBAC4AppEntry', 'Get-RegisteredAppWithPermission', 'Invoke-RBAC4AppConfig', 'New-RBAC4AppConfig', 'New-RBAC4AppDistributionGroup', 'New-RBAC4AppEntry', 'New-RBAC4AppUnifiedGroup', 'New-RegisteredApp', 'Register-EXOServicePrincipal', 'Remove-RBAC4AppEntry', 'Set-RBAC4AppEntry', 'Test-RBAC4AppEntry')
    }

    It 'exports the pre-0.6.0 RBACforApp names as aliases to the RBAC4App functions' {
        $aliasMap = [ordered]@{
            'New-RBACforAppEntry'             = 'New-RBAC4AppEntry'
            'Get-RBACforAppEntry'             = 'Get-RBAC4AppEntry'
            'Set-RBACforAppEntry'             = 'Set-RBAC4AppEntry'
            'Test-RBACforAppEntry'            = 'Test-RBAC4AppEntry'
            'Remove-RBACforAppEntry'          = 'Remove-RBAC4AppEntry'
            'New-RBACforAppUnifiedGroup'      = 'New-RBAC4AppUnifiedGroup'
            'New-RBACforAppDistributionGroup' = 'New-RBAC4AppDistributionGroup'
        }
        foreach ($old in $aliasMap.Keys) {
            $cmd = Get-Command -Module EXORBACforAppManagement -Name $old -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty -Because "alias '$old' should be exported"
            $cmd.CommandType | Should -Be 'Alias'
            $cmd.ResolvedCommand.Name | Should -Be $aliasMap[$old]
        }
    }

    It 'does not export the private helpers' {
        foreach ($helper in 'Get-SafeName', 'Get-NormalizeRole', 'ConvertTo-AppRole', 'Get-AppRoleMap', 'Get-LegacyScopeRoleMap', 'Resolve-AppRolePermissionValue', 'ConvertTo-RBAC4AppYaml', 'ConvertFrom-RBAC4AppYaml') {
            (Get-Command -Module EXORBACforAppManagement -Name $helper -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }

    It 'makes the private helpers available inside the module scope' {
        InModuleScope EXORBACforAppManagement {
            (Get-Command Get-SafeName, Get-NormalizeRole, ConvertTo-AppRole, Get-AppRoleMap, Get-LegacyScopeRoleMap, Resolve-AppRolePermissionValue, ConvertTo-RBAC4AppYaml, ConvertFrom-RBAC4AppYaml).Count | Should -Be 8
        }
    }
}
