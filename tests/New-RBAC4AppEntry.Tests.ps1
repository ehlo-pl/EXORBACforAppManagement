#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs for the external Graph/EXO cmdlets so Pester can mock them in the module
    # scope without the real Microsoft.Graph / ExchangeOnlineManagement modules installed.
    # They must be global so the module's session state (a child of global) can resolve them.
    function global:Get-MgContext { }
    function global:Get-MgServicePrincipal { }
    function global:Get-UnifiedGroup { }
    function global:Get-UnifiedGroupLinks { }
    function global:New-UnifiedGroup { }
    function global:Set-UnifiedGroup { }
    function global:Add-UnifiedGroupLinks { }
    function global:New-ServicePrincipal { }
    function global:Get-ServicePrincipal { }
    function global:Get-Recipient { }
    function global:New-ManagementRoleAssignment { }
    function global:Get-ManagementRoleAssignment { }
    function global:Get-DistributionGroupMember { }
    function global:Add-DistributionGroupMember { }

    $script:Sp = [pscustomobject]@{
        DisplayName = 'Contoso'
        AppId       = '11111111-1111-1111-1111-111111111111'
        Id          = '22222222-2222-2222-2222-222222222222'
    }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-MgContext','Get-MgServicePrincipal','Get-UnifiedGroup','Get-UnifiedGroupLinks','New-UnifiedGroup','Set-UnifiedGroup','Add-UnifiedGroupLinks','New-ServicePrincipal','Get-ServicePrincipal','Get-Recipient','New-ManagementRoleAssignment','Get-ManagementRoleAssignment','Get-DistributionGroupMember','Add-DistributionGroupMember') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppEntry SP resolution' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'admin@contoso.com' } }
    }

    It 'records an error when no SP matches the AppId' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { @() }

        $r = New-RBAC4AppEntry -AppId '33333333-3333-3333-3333-333333333333' -WhatIf
        $r.Errors -join ';' | Should -Match 'No service principal found'
    }

    It 'records an error when the display name is ambiguous' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { @($script:Sp, $script:Sp) }

        $r = New-RBAC4AppEntry -RegisteredAppName 'dup' -WhatIf
        $r.Errors -join ';' | Should -Match 'Ambiguous'
    }
}

Describe 'New-RBAC4AppEntry -WhatIf' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { $script:Sp }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup {
            [pscustomobject]@{ OwnerRequested = 'owner@contoso.com'; OwnerAdded = 'owner@contoso.com' }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = 'g'; ManagedBy = @() } }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Add-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement New-ServicePrincipal { }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Export-Clixml { }
    }

    It 'normalizes the role and builds the assignment name' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -Members 'shared@contoso.com' -Role 'Mail.Send' -WhatIf
        $r.RolesNormalized | Should -Contain 'Application Mail.Send'
        $r.RoleAssignmentsName[0] | Should -BeLike 'AppMailSend-*'
    }

    It 'reports the requested and added Unified Group owner' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ManagedBy 'owner@contoso.com' -Role 'Mail.Send' -WhatIf
        $r.PSObject.Properties.Name | Should -Contain 'OwnerRequested'
        $r.PSObject.Properties.Name | Should -Contain 'OwnerAdded'
        $r.OwnerRequested | Should -Be 'owner@contoso.com'
    }

    It 'uses AccessGroupName as the Unified Group scope' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupName 'RBAC-AppScope-Contoso' -Role 'Mail.Send' -WhatIf

        $r.ScopeGroupName | Should -Be 'RBAC-AppScope-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 1 -ParameterFilter {
            $Name -eq 'RBAC-AppScope-Contoso'
        }
    }

    It 'throws when AccessGroupName and GroupPrefix are both explicitly set' {
        {
            New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupName 'RBAC-AppScope-Contoso' -GroupPrefix 'Um365Prod' -WhatIf
        } | Should -Throw '*cannot be used together*'
    }

    It 'does not perform any mutating EXO calls under -WhatIf' {
        $null = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ServicePrincipal -Times 0
    }

    It 'reports the pre-existing and newly-added members in MembersFinal' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @([pscustomobject]@{ PrimarySmtpAddress = 'existing@contoso.com'; Name = 'existing' }) }

        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -Members 'shared@contoso.com' -Role 'Mail.Send' -Confirm:$false

        $r.MembersFinal | Should -Contain 'existing@contoso.com'
        $r.MembersFinal | Should -Contain 'shared@contoso.com'
    }

    It 'skips creating a role assignment that already exists and is scoped to the target group' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = 'Um365RAo1-Contoso' }
        }

        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -Confirm:$false

        $r.RoleAssignments | Should -HaveCount 1
        ($r.Warnings -join ';') | Should -Match 'already exists and is scoped'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'warns instead of erroring when a same-named assignment exists but is scoped elsewhere' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = 'SomeOtherGroup' }
        }

        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -Confirm:$false

        $r.Errors | Should -BeNullOrEmpty
        ($r.Warnings -join ';') | Should -Match "scoped to 'SomeOtherGroup', not 'Um365RAo1-Contoso'"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }
}

Describe 'New-RBAC4AppEntry -AccessGroupType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { $script:Sp }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup { [pscustomobject]@{ OwnerRequested = 'o'; OwnerAdded = 'o' } }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppDistributionGroup { [pscustomobject]@{ OwnerRequested = 'o'; OwnerAdded = 'o'; Group = [pscustomobject]@{ Name = 'g' } } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; DisplayName = 'mesg'; ManagedBy = @() } }
        Mock -ModuleName EXORBACforAppManagement Register-EXOServicePrincipal { }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        Mock -ModuleName EXORBACforAppManagement Add-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement Add-DistributionGroupMember { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Export-Clixml { }
    }

    It 'DistributionList: provisions a distribution list and adds members via Add-DistributionGroupMember' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType DistributionList -Members 'shared@contoso.com' -Role 'Mail.Send' -Confirm:$false
        $r.AccessGroupType | Should -Be 'DistributionList'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-DistributionGroupMember -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 0
    }

    It 'MailEnabledSecurityGroup: references an existing group, never creates, and skips members' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -Members 'shared@contoso.com' -Role 'Mail.Send' -Confirm:$false
        $r.AccessGroupType  | Should -Be 'MailEnabledSecurityGroup'
        $r.ScopeGroupName | Should -Be 'OnPrem-Scope'
        ($r.Warnings -join ';') | Should -Match 'managed on-premises'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-DistributionGroupMember -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1
    }

    It 'MailEnabledSecurityGroup: records an error when -AccessGroupName is omitted' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -Role 'Mail.Send' -Confirm:$false
        ($r.Errors -join ';') | Should -Match 'AccessGroupName is required'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'MailEnabledSecurityGroup: records an error when the referenced group does not exist' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { }
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'Missing-Scope' -Role 'Mail.Send' -Confirm:$false
        ($r.Errors -join ';') | Should -Match 'was not found'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'MailEnabledSecurityGroup: warns that -ManagedBy and -BootstrapMember are ignored when set to non-default values' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -ManagedBy 'custom-owner@contoso.com' -BootstrapMember 'custom-bootstrap@contoso.com' -Role 'Mail.Send' -Confirm:$false
        ($r.Warnings -join ';') | Should -Match 'ManagedBy was ignored'
        ($r.Warnings -join ';') | Should -Match 'BootstrapMember was ignored'
    }

    It 'MailEnabledSecurityGroup: does not warn about -ManagedBy/-BootstrapMember when left at their defaults' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -Role 'Mail.Send' -Confirm:$false
        ($r.Warnings -join ';') | Should -Not -Match 'ManagedBy was ignored'
        ($r.Warnings -join ';') | Should -Not -Match 'BootstrapMember was ignored'
    }
}
