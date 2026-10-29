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

    It 'exports all public functions' {
        $exported = (Get-Command -Module EXORBACforAppManagement -CommandType Function).Name | Sort-Object
        $exported | Should -Be @('Convert-ApplicationAccessPolicyToRBAC', 'Get-RBAC4AppEntry', 'Get-RBAC4AppRoleAssignment', 'Invoke-MsGraphEntraIDApiPerm', 'Invoke-RBAC4AppConfig', 'New-RBAC4AppConfig', 'New-RBAC4AppDistributionGroup', 'New-RBAC4AppEntry', 'New-RBAC4AppManagementScope', 'New-RBAC4AppUnifiedGroup', 'New-RegisteredApp', 'Register-EXOServicePrincipal', 'Remove-RBAC4AppEntry', 'Resolve-ApplicationAccessPolicy', 'Set-RBAC4AppEntry', 'Test-RBAC4AppEntry')
    }

    It 'exports no aliases' {
        @(Get-Command -Module EXORBACforAppManagement -CommandType Alias) | Should -BeNullOrEmpty
    }

    It 'keeps the manifest FunctionsToExport in sync with Public/*.ps1' {
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
        $publicNames = Get-ChildItem -Path (Join-Path (Split-Path $script:ManifestPath) 'Public') -Filter '*.ps1' | ForEach-Object BaseName
        @($manifest.FunctionsToExport) | Sort-Object | Should -Be @($publicNames | Sort-Object)
    }

    It 'declares an empty AliasesToExport in the manifest' {
        @((Import-PowerShellDataFile -Path $script:ManifestPath).AliasesToExport) | Should -BeNullOrEmpty
    }

    It 'documents every exported function in AGENTS.md and README.md' {
        $repoRoot = Join-Path $PSScriptRoot '..'
        $agents = Get-Content -LiteralPath (Join-Path $repoRoot 'AGENTS.md') -Raw
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $missing = foreach ($name in (Import-PowerShellDataFile -Path $script:ManifestPath).FunctionsToExport) {
            if ($agents -notmatch [regex]::Escape($name)) { "AGENTS.md: $name" }
            if ($readme -notmatch [regex]::Escape($name)) { "README.md: $name" }
        }
        @($missing) | Should -BeNullOrEmpty
    }

    It 'states the correct exported-function count in the docs' {
        $count = @((Import-PowerShellDataFile -Path $script:ManifestPath).FunctionsToExport).Count
        $repoRoot = Join-Path $PSScriptRoot '..'
        (Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw) | Should -Match "$count exported functions"
        (Get-Content -LiteralPath (Join-Path $repoRoot 'AGENTS.md') -Raw) | Should -Match "FunctionsToExport = $count public"
    }

    It 'does not export the private helpers' {
        foreach ($helper in 'Format-RBAC4AppSafeName', 'ConvertTo-RBAC4AppRoleName', 'Get-RBAC4AppScopeGroupName', 'Get-RBAC4AppRoleAssignmentName', 'Get-RBAC4AppDefaultGroupPrefix', 'Get-AppRoleMap', 'Get-LegacyScopeRoleMap', 'Resolve-AppRolePermissionValue', 'ConvertTo-RBAC4AppYaml', 'ConvertFrom-RBAC4AppYaml') {
            (Get-Command -Module EXORBACforAppManagement -Name $helper -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }

    It 'makes the private helpers available inside the module scope' {
        InModuleScope EXORBACforAppManagement {
            (Get-Command Format-RBAC4AppSafeName, ConvertTo-RBAC4AppRoleName, Get-RBAC4AppScopeGroupName, Get-RBAC4AppRoleAssignmentName, Get-RBAC4AppDefaultGroupPrefix, Get-AppRoleMap, Get-LegacyScopeRoleMap, Resolve-AppRolePermissionValue, ConvertTo-RBAC4AppYaml, ConvertFrom-RBAC4AppYaml).Count | Should -Be 10
        }
    }
}
