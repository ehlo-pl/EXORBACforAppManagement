BeforeAll {
    Import-Module "$PSScriptRoot/../src/EXORBACforAppManagement/EXORBACforAppManagement.psd1" -Force
    function global:Get-ConnectionInformation { [CmdletBinding()] param() }
    function global:Test-RBAC4AppPresentStub { }
}

AfterAll {
    Remove-Item -Path Function:\global:Test-RBAC4AppPresentStub -ErrorAction SilentlyContinue
}

Describe 'Assert-RBAC4AppExoCommand' {
    It 'returns nothing when every command exists' {
        InModuleScope EXORBACforAppManagement {
            Assert-RBAC4AppExoCommand -Name 'Test-RBAC4AppPresentStub' | Should -BeNullOrEmpty
        }
    }

    It 'points at PIM activation and a reconnect when connected but the cmdlet is missing' {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ State = 'Connected' } }
        InModuleScope EXORBACforAppManagement {
            { Assert-RBAC4AppExoCommand -Name 'Test-RBAC4AppPresentStub', 'New-RBAC4AppMissingCmdletXyz' } |
                Should -Throw -ExpectedMessage '*New-RBAC4AppMissingCmdletXyz*Privileged Identity Management*reconnect*'
        }
    }

    It 'does not list the commands that are present' {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ State = 'Connected' } }
        InModuleScope EXORBACforAppManagement {
            try { Assert-RBAC4AppExoCommand -Name 'Test-RBAC4AppPresentStub', 'New-RBAC4AppMissingCmdletXyz' }
            catch { $_.Exception.Message | Should -Not -BeLike '*Test-RBAC4AppPresentStub*' }
        }
    }

    It 'asks to connect when there is no Exchange Online connection' {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { }
        InModuleScope EXORBACforAppManagement {
            { Assert-RBAC4AppExoCommand -Name 'New-RBAC4AppMissingCmdletXyz' } |
                Should -Throw -ExpectedMessage '*Connect-ExchangeOnline using an account*'
        }
    }

    It 'treats a failing connection read as not connected' {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { throw 'boom' }
        InModuleScope EXORBACforAppManagement {
            { Assert-RBAC4AppExoCommand -Name 'New-RBAC4AppMissingCmdletXyz' } |
                Should -Throw -ExpectedMessage '*Connect-ExchangeOnline using an account*'
        }
    }
}
