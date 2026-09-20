#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI.
    function global:New-ServicePrincipal { [CmdletBinding()] param([string]$AppId, [string]$ObjectId, [string]$DisplayName) }
    function global:Get-ServicePrincipal { [CmdletBinding()] param([string]$Identity) }

    $script:AppId    = '11111111-1111-1111-1111-111111111111'
    $script:ObjectId = '22222222-2222-2222-2222-222222222222'
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'New-ServicePrincipal', 'Get-ServicePrincipal') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Register-EXOServicePrincipal' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }
    }

    It 'invokes New-ServicePrincipal with the supplied identifiers' {
        Mock -ModuleName EXORBACforAppManagement New-ServicePrincipal { [pscustomobject]@{ DisplayName = $DisplayName } }

        $null = Register-EXOServicePrincipal -AppId $script:AppId -ObjectId $script:ObjectId -DisplayName 'Contoso_SP' -Confirm:$false
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ServicePrincipal -Times 1 -ParameterFilter {
            $AppId -eq $script:AppId -and $ObjectId -eq $script:ObjectId -and $DisplayName -eq 'Contoso_SP'
        }
    }

    It 'does not create under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement New-ServicePrincipal { }
        $null = Register-EXOServicePrincipal -AppId $script:AppId -ObjectId $script:ObjectId -DisplayName 'Contoso_SP' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ServicePrincipal -Times 0
    }

    It 'skips creation and returns the existing service principal when one already matches by AppId' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = $script:AppId }) }
        Mock -ModuleName EXORBACforAppManagement New-ServicePrincipal { throw 'should not be called' }

        $r = Register-EXOServicePrincipal -AppId $script:AppId -ObjectId $script:ObjectId -DisplayName 'Contoso_SP' -Confirm:$false -WarningAction SilentlyContinue

        $r.DisplayName | Should -Be 'Contoso_SP'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ServicePrincipal -Times 0
    }

    It 'skips creation when one already matches by DisplayName' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }) }
        Mock -ModuleName EXORBACforAppManagement New-ServicePrincipal { throw 'should not be called' }

        $null = Register-EXOServicePrincipal -AppId $script:AppId -ObjectId $script:ObjectId -DisplayName 'Contoso_SP' -Confirm:$false -WarningAction SilentlyContinue

        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ServicePrincipal -Times 0
    }

    It 'warns when skipping creation because one already exists' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = $script:AppId }) }

        $warnings = $null
        $null = Register-EXOServicePrincipal -AppId $script:AppId -ObjectId $script:ObjectId -DisplayName 'Contoso_SP' -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ';') | Should -Match 'already exists'
    }
}
