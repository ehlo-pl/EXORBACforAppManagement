#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-MgServicePrincipal { }
    function global:Get-MgContext { }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-MgServicePrincipal', 'Get-MgContext') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppConfig' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext {
            [pscustomobject]@{ TenantId = 'tenant-id-123'; Account = 'admin@contoso.com' }
        }
    }

    It 'resolves SP by display name and writes YAML with correct Application fields' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-obj-id'; AppId = 'app-client-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -Role 'Mail.Send' -Members 'shared@contoso.com' -OutputPath $TestDrive -Confirm:$false

        $outFile         | Should -Not -BeNullOrEmpty
        (Test-Path $outFile) | Should -BeTrue
        $content = Get-Content $outFile -Raw
        $content | Should -Match 'AppId:.*app-client-id'
        $content | Should -Match 'SpObjectId:.*sp-obj-id'
        $content | Should -Match 'DisplayName:.*Contoso'
        $content | Should -Match 'TenantId:.*tenant-id-123'
    }

    It 'normalises short role names to Application form in the YAML' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -Role 'Mail.Send' -OutputPath $TestDrive -Confirm:$false

        (Get-Content $outFile -Raw) | Should -Match 'Application Mail\.Send'
    }

    It 'resolves SP by AppId' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = '11111111-1111-1111-1111-111111111111'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -AppId '11111111-1111-1111-1111-111111111111' `
            -OutputPath $TestDrive -Confirm:$false
        (Test-Path $outFile) | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 1
    }

    It 'resolves SP by SpObjectId' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -SpObjectId '22222222-2222-2222-2222-222222222222' `
            -OutputPath $TestDrive -Confirm:$false
        (Test-Path $outFile) | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 1
    }

    It 'writes nothing and returns nothing under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $emptyDir = Join-Path $TestDrive 'whatif-check'
        $null = New-Item -ItemType Directory -Path $emptyDir -Force
        $result = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $emptyDir -WhatIf
        $result | Should -BeNullOrEmpty
        @(Get-ChildItem $emptyDir -Filter '*.yml').Count | Should -Be 0
    }

    It 'records an error when the SP is not found by name' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { @() }
        $err = $null
        $null = New-RBAC4AppConfig -RegisteredAppName 'Unknown App' `
            -OutputPath $TestDrive -Confirm:$false -ErrorVariable err
        $err | Should -Not -BeNullOrEmpty
    }

    It 'includes AccessGroupType and Members in the YAML' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -AccessGroupType DistributionList -Members 'box@contoso.com' `
            -OutputPath $TestDrive -Confirm:$false

        $content = Get-Content $outFile -Raw
        $content | Should -Match 'AccessGroupType: DistributionList'
        $content | Should -Match 'box@contoso\.com'
    }
}
