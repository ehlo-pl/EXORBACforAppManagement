#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI.
    function global:Get-ConnectionInformation { }
    function global:Get-UnifiedGroup { }
    function global:New-UnifiedGroup { param($DisplayName, $Name, $Alias, $AccessType, [string[]]$ManagedBy, $Members) }
    function global:Set-UnifiedGroup { param($Identity) }
    function global:Get-Recipient { }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ConnectionInformation','Get-UnifiedGroup','New-UnifiedGroup','Set-UnifiedGroup','Get-Recipient') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppUnifiedGroup' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Set-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'owner@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Save-RBAC4AppChangeReferenceRecord { Join-Path $TestDrive "$ChangeReference.yaml" }
    }

    It 'creates and configures the group when it does not exist' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { } # not found, then configured lookup
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g'; AccessType = 'Private' } }

        $res = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-UnifiedGroup -Times 1
        $res.AlreadyExisted | Should -BeFalse
        $res.OwnerRequested | Should -Be @('owner@contoso.com')
        $res.OwnerAdded     | Should -Be @('owner@contoso.com')
    }

    It 'strips spaces and other Alias-unsafe characters from -Name' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g'; AccessType = 'Private' } }

        $res = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso Mail App 1642232032' -ManagedBy 'owner@contoso.com' -Confirm:$false

        $res.Name | Should -Be 'Um365RAo1-ContosoMailApp1642232032'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 1 -ParameterFilter {
            $Name -eq 'Um365RAo1-ContosoMailApp1642232032' -and $Alias -eq 'Um365RAo1-ContosoMailApp1642232032'
        }
    }

    It 'creates the group with multiple owners, each resolved independently' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g'; AccessType = 'Private' } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            param($Identity)
            [pscustomobject]@{ PrimarySmtpAddress = $Identity }
        }

        $res = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner1@contoso.com', 'owner2@contoso.com' -Confirm:$false

        $res.OwnerRequested | Should -Be @('owner1@contoso.com', 'owner2@contoso.com')
        $res.OwnerAdded     | Should -Be @('owner1@contoso.com', 'owner2@contoso.com')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 1 -ParameterFilter {
            (Compare-Object $ManagedBy @('owner1@contoso.com', 'owner2@contoso.com')).Count -eq 0
        }
    }

    It 'falls back to the raw value for an owner that cannot be resolved, without dropping the others' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g'; AccessType = 'Private' } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            param($Identity)
            if ($Identity -eq 'owner1@contoso.com') { [pscustomobject]@{ PrimarySmtpAddress = $Identity } }
        }

        $res = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner1@contoso.com', 'missing-owner@contoso.com' -Confirm:$false

        $res.OwnerAdded | Should -Be @('owner1@contoso.com', 'missing-owner@contoso.com')
    }

    It 'warns and does not create when the group already exists' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = 'g'; ManagedBy = @('existing@contoso.com') } }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { }

        $warn = $null
        $res = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false -WarningVariable warn
        ($warn.Message -join ';') | Should -Match 'already exists'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 0
        $res.AlreadyExisted | Should -BeTrue
        $res.OwnerRequested | Should -Be @('owner@contoso.com')
        $res.OwnerAdded     | Should -Be @('existing@contoso.com')
    }

    It 'stores ChangeReference in a local metadata file when creating the group' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g'; AccessType = 'Private' } }

        $res = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -ChangeReference 'CHG123456' -Confirm:$false

        $res.ChangeReference | Should -Be 'CHG123456'
        $res.ChangeReferencePath | Should -Be (Join-Path $TestDrive 'CHG123456.yaml')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Save-RBAC4AppChangeReferenceRecord -Times 1 -ParameterFilter {
            $ChangeReference -eq 'CHG123456' -and $AccessGroupType -eq 'M365Group' -and $ScopeGroupName -eq 'Um365RAo1-Contoso'
        }
    }

    It 'stores ChangeReference in a local metadata file when the group already exists' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup {
            [pscustomobject]@{
                DisplayName = 'g'
                Identity    = 'g'
                ManagedBy   = @('existing@contoso.com')
            }
        }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { }

        $res = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -ChangeReference 'INC987654' -Confirm:$false

        $res.ChangeReferencePath | Should -Be (Join-Path $TestDrive 'INC987654.yaml')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Save-RBAC4AppChangeReferenceRecord -Times 1 -ParameterFilter {
            $ChangeReference -eq 'INC987654' -and $AccessGroupType -eq 'M365Group' -and $ScopeGroupName -eq 'Um365RAo1-Contoso'
        }
    }

    It 'does not create under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { }

        $null = New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-Contoso' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 0
    }
}
