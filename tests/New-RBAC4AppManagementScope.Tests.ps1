#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force
    function global:Get-ManagementScope { [CmdletBinding()] param([string]$Identity) }
    function global:New-ManagementScope { [CmdletBinding()] param([string]$Name, [string]$RecipientRestrictionFilter) }
    function global:Set-ManagementScope { [CmdletBinding()] param([string]$Identity, [string]$RecipientRestrictionFilter) }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ManagementScope', 'New-ManagementScope', 'Set-ManagementScope') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppManagementScope' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter } }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementScope { }
    }

    It 'creates a missing scope' {
        $r = New-RBAC4AppManagementScope -Name 'MSRAo1P-Contoso' -RecipientRestrictionFilter "CustomAttribute1 -eq 'x'" -Confirm:$false
        $r.Created | Should -BeTrue
        $r.AlreadyExisted | Should -BeFalse
        $r.Scope.Name | Should -Be 'MSRAo1P-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 1 -ParameterFilter {
            $Name -eq 'MSRAo1P-Contoso' -and $RecipientRestrictionFilter -eq "CustomAttribute1 -eq 'x'"
        }
    }

    It 'leaves an existing scope with an equivalent filter alone' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(CustomAttribute1 -eq 'x')" } }
        $r = New-RBAC4AppManagementScope -Name 'MSRAo1P-Contoso' -RecipientRestrictionFilter "CustomAttribute1 -eq 'x'" -Confirm:$false
        $r.AlreadyExisted | Should -BeTrue
        $r.Created | Should -BeFalse
        $r.FilterUpdated | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 0
    }

    It 'updates the filter of an existing scope when it differs' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(CustomAttribute1 -eq 'old')" } }
        $r = New-RBAC4AppManagementScope -Name 'MSRAo1P-Contoso' -RecipientRestrictionFilter "CustomAttribute1 -eq 'new'" -Confirm:$false
        $r.FilterUpdated | Should -BeTrue
        $r.PreviousFilter | Should -Be "(CustomAttribute1 -eq 'old')"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 1 -ParameterFilter { $RecipientRestrictionFilter -eq "CustomAttribute1 -eq 'new'" }
    }

    It 'warns and keeps the current filter with -NoUpdate' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(CustomAttribute1 -eq 'old')" } }
        $r = New-RBAC4AppManagementScope -Name 'MSRAo1P-Contoso' -RecipientRestrictionFilter "CustomAttribute1 -eq 'new'" -NoUpdate -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.FilterUpdated | Should -BeFalse
        $r.RecipientRestrictionFilter | Should -Be "(CustomAttribute1 -eq 'old')"
        ($w -join ';') | Should -Match 'different filter'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 0
    }

    It 'changes nothing under -WhatIf' {
        $r = New-RBAC4AppManagementScope -Name 'MSRAo1P-Contoso' -RecipientRestrictionFilter "CustomAttribute1 -eq 'x'" -WhatIf
        $r.Created | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 0
    }
}
