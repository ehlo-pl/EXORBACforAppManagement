#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI.
    function global:Get-DistributionGroup { }
    function global:New-DistributionGroup { param($Name, $DisplayName, $Alias, $Type, [string[]]$ManagedBy, $Members, $Notes) }
    function global:Set-DistributionGroup { param($Identity, $Notes) }
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
        $res.OwnerRequested | Should -Be @('owner@contoso.com')
        $res.OwnerAdded     | Should -Be @('owner@contoso.com')
    }

    It 'creates the list with multiple owners, each resolved independently' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            param($Identity)
            [pscustomobject]@{ PrimarySmtpAddress = $Identity }
        }

        $res = New-RBAC4AppDistributionGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner1@contoso.com', 'owner2@contoso.com' -Confirm:$false

        $res.OwnerRequested | Should -Be @('owner1@contoso.com', 'owner2@contoso.com')
        $res.OwnerAdded     | Should -Be @('owner1@contoso.com', 'owner2@contoso.com')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1 -ParameterFilter {
            (Compare-Object $ManagedBy @('owner1@contoso.com', 'owner2@contoso.com')).Count -eq 0
        }
    }

    It 'warns and does not create when the list already exists' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = 'g'; ManagedBy = @('existing@contoso.com') } }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $warn = $null
        $res = New-RBAC4AppDistributionGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false -WarningVariable warn
        ($warn.Message -join ';') | Should -Match 'already exists'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
        $res.AlreadyExisted | Should -BeTrue
        $res.OwnerRequested | Should -Be @('owner@contoso.com')
        $res.OwnerAdded     | Should -Be @('existing@contoso.com')
    }

    It 'stores ChangeReference in Notes when creating the list' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -ChangeReference 'CHG123456' -Confirm:$false

        $res.ChangeReference | Should -Be 'CHG123456'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1 -ParameterFilter {
            $Notes -eq 'RBAC4App-ChangeReference: CHG123456'
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1 -ParameterFilter {
            $Notes -eq 'RBAC4App-ChangeReference: CHG123456'
        }
    }

    It 'updates ChangeReference in Notes without removing unrelated existing notes' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            [pscustomobject]@{
                DisplayName = 'g'
                Identity    = 'g'
                ManagedBy   = @('existing@contoso.com')
                Notes       = "Keep me`nRBAC4App-ChangeReference: OLD"
            }
        }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $res = New-RBAC4AppDistributionGroup -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -ChangeReference 'INC987654' -Confirm:$false

        $res.NotesUpdated | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1 -ParameterFilter {
            $Notes -eq "Keep me$([System.Environment]::NewLine)RBAC4App-ChangeReference: INC987654"
        }
    }

    It 'does not create under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $null = New-RBAC4AppDistributionGroup -Name 'Um365RAo1-Contoso' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
    }

    It 'derives name from -AppName using default prefix UDLRAo1' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -AppName 'Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false
        $res.Name | Should -Be 'UDLRAo1-Contoso'
        $res.AlreadyExisted | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1
    }

    It 'derives name from -AppName and explicit -Prefix' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -AppName 'Contoso' -Prefix 'MYORG' -ManagedBy 'owner@contoso.com' -Confirm:$false
        $res.Name | Should -Be 'MYORG-Contoso'
        $res.AlreadyExisted | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1
    }

    It 'strips spaces and other Alias-unsafe characters from a name derived via -AppName' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -AppName 'Contoso Mail App 1642232032' -ManagedBy 'owner@contoso.com' -Confirm:$false

        $res.Name | Should -Be 'UDLRAo1-ContosoMailApp1642232032'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1 -ParameterFilter {
            $Name -eq 'UDLRAo1-ContosoMailApp1642232032' -and $Alias -eq 'UDLRAo1-ContosoMailApp1642232032'
        }
    }

    It 'strips spaces and other Alias-unsafe characters from an explicit -Name too' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -Name 'UDLRAo1-Contoso, Mail; App' -ManagedBy 'owner@contoso.com' -Confirm:$false

        $res.Name | Should -Be 'UDLRAo1-ContosoMailApp'
    }
}
