#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI.
    function global:Get-DistributionGroup { }
    function global:New-DistributionGroup { }
    function global:Set-DistributionGroup { }
    function global:Get-Recipient { }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-DistributionGroup','New-DistributionGroup','Set-DistributionGroup','Get-Recipient') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppDistributionGroup' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'owner@contoso.com' } }
    }

    It 'creates and configures the list when it does not exist' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { } # not found, then configured lookup
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1
        $res.AlreadyExisted | Should -BeFalse
        $res.OwnerRequested | Should -Be 'owner@contoso.com'
        $res.OwnerAdded     | Should -Be 'owner@contoso.com'
    }

    It 'warns and does not create when the list already exists' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = 'g'; ManagedBy = @('existing@contoso.com') } }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $warn = $null
        $res = New-RBAC4AppDistributionGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false -WarningVariable warn
        ($warn.Message -join ';') | Should -Match 'already exists'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
        $res.AlreadyExisted | Should -BeTrue
        $res.OwnerRequested | Should -Be 'owner@contoso.com'
        $res.OwnerAdded     | Should -Be 'existing@contoso.com'
    }

    It 'does not create under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $null = New-RBAC4AppDistributionGroup -Name 'Um365RAo1-Contoso' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
    }
}
