#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs for the external EXO cmdlets so Pester can mock them in the module scope
    # without the real ExchangeOnlineManagement module installed. They must be global so the
    # module's session state (a child of global) can resolve them. No Microsoft Graph stubs are
    # needed: SP resolution goes through Get-ServicePrincipal (EXO) only. The delegated module
    # functions (New-RBAC4AppUnifiedGroup / Register-EXOServicePrincipal) are mocked directly
    # with -ModuleName so their internals are not exercised here.
    function global:Get-ConnectionInformation { }
    function global:Get-UnifiedGroup { param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { param([string]$Identity, [string]$LinkType) }
    function global:Add-UnifiedGroupLinks { param([string]$Identity, [string]$LinkType, [string]$Links) }
    function global:Get-ServicePrincipal { param([string]$Identity) }
    function global:Get-Recipient { param([string]$Identity) }
    function global:Get-ManagementRoleAssignment { param([string]$Identity, [string]$Role) }
    function global:New-ManagementRoleAssignment { param($App, $Role, $RecipientGroupScope, $Name) }
    function global:Remove-ManagementRoleAssignment { param([string]$Identity) }
    function global:Get-DistributionGroup { param([string]$Identity) }
    function global:Get-DistributionGroupMember { param([string]$Identity) }
    function global:Add-DistributionGroupMember { param([string]$Identity, [string]$Member) }

    $script:ExoSp = [pscustomobject]@{
        DisplayName = 'Contoso_SP'
        AppId       = '11111111-1111-1111-1111-111111111111'
        ObjectId    = '22222222-2222-2222-2222-222222222222'
    }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ConnectionInformation','Get-UnifiedGroup','Get-UnifiedGroupLinks','Add-UnifiedGroupLinks','Get-ServicePrincipal','Get-Recipient','Get-ManagementRoleAssignment','New-ManagementRoleAssignment','Remove-ManagementRoleAssignment','Get-DistributionGroup','Get-DistributionGroupMember','Add-DistributionGroupMember') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Set-RBAC4AppEntry SP resolution' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
    }

    It 'records an error when no EXO service principal matches the AppId' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }

        $r = Set-RBAC4AppEntry -AppId '33333333-3333-3333-3333-333333333333' -WhatIf
        $r.Errors -join ';' | Should -Match 'not enough information to register one'
    }

    It 'records an error when the display name is ambiguous' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            @(
                [pscustomobject]@{ DisplayName = 'dup_SP'; AppId = '66666666-6666-6666-6666-666666666666'; ObjectId = '77777777-7777-7777-7777-777777777777' },
                [pscustomobject]@{ DisplayName = 'dup_SP'; AppId = '88888888-8888-8888-8888-888888888888'; ObjectId = '99999999-9999-9999-9999-999999999999' }
            )
        }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'dup' -WhatIf
        $r.Errors -join ';' | Should -Match 'Ambiguous'
    }
}

Describe 'Set-RBAC4AppEntry reconcile' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        # Everything present by default: group exists, EXO SP exists, assignment exists scoped to current group.
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = $Identity } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111' }) }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = $Identity; Name = $Identity } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{
                Name                      = $Identity
                Role                      = 'Application Mail.Send'
                RecipientWriteScope       = 'Group'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'
            }
        }
        # Delegated module functions + mutating cmdlets.
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); AlreadyExisted = $false; Group = [pscustomobject]@{ Identity = $Name } } }
        Mock -ModuleName EXORBACforAppManagement Register-EXOServicePrincipal { [pscustomobject]@{ DisplayName = $DisplayName } }
        Mock -ModuleName EXORBACforAppManagement Add-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
    }

    It 'leaves a fully-configured app on its group untouched and reports IsValid' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send'

        $r.IsValid | Should -BeTrue
        $r.RoleAssignmentsUnchanged | Should -Contain 'AppMailSend-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Register-EXOServicePrincipal -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 0
    }

    It 'creates only the missing role assignment, not the existing group' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.RoleAssignmentsCreated | Should -Contain 'AppMailSend-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 0
    }

    It 'creates the Unified Group when it is missing' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.ScopeGroupCreated | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 1
    }

    It 'creates the Exchange Online service principal when it is missing, bootstrapped from AppId/SpObjectId/RegisteredAppName' {
        # No existing EXO pointer matches at all: resolution falls back to the bootstrap triple.
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -AppId '11111111-1111-1111-1111-111111111111' -SpObjectId '22222222-2222-2222-2222-222222222222' -Role 'Mail.Send' -Confirm:$false

        $r.ExoServicePrincipalCreated | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Register-EXOServicePrincipal -Times 1
    }

    It 'adds a requested member that is not already in the group (additive)' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Members 'new@contoso.com' -Confirm:$false

        $r.MembersAdded | Should -Contain 'new@contoso.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 1
    }

    It 'does not re-add a member already present in the group' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @([pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' }) }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Members 'shared@contoso.com'

        $r.MembersAlreadyPresent | Should -Contain 'shared@contoso.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
    }

    It 're-scopes the assignment onto a new group when -NewGroupPrefix is supplied' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -NewGroupPrefix 'Um365Prod' -Confirm:$false

        $r.GroupChanged | Should -BeTrue
        $r.TargetGroupName | Should -Be 'Um365Prod-Contoso'
        $r.RoleAssignmentsRescoped | Should -Contain 'AppMailSend-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1
    }

    It 'makes no mutating calls under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            @([pscustomobject]@{ DisplayName = 'Contoso'; AppId = $null; ObjectId = '22222222-2222-2222-2222-222222222222' })
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }

        $null = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Members 'new@contoso.com' -WhatIf

        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Register-EXOServicePrincipal -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 0
    }
}

Describe 'Set-RBAC4AppEntry -AccessGroupType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = $Identity; Name = $Identity; DisplayName = $Identity; ManagedBy = @() } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppDistributionGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); AlreadyExisted = $false; Group = [pscustomobject]@{ Identity = $Name } } }
        Mock -ModuleName EXORBACforAppManagement Register-EXOServicePrincipal { }
        Mock -ModuleName EXORBACforAppManagement Add-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement Add-DistributionGroupMember { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
    }

    It 'DistributionList: creates the list when missing and adds members via Add-DistributionGroupMember' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }          # missing -> create
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() } # empty -> member added

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType DistributionList -Members 'new@contoso.com' -Confirm:$false

        $r.AccessGroupType | Should -Be 'DistributionList'
        $r.ScopeGroupCreated | Should -BeTrue
        $r.MembersAdded | Should -Contain 'new@contoso.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-DistributionGroupMember -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
    }

    It 'MailEnabledSecurityGroup: references an existing group and skips membership' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -Members 'new@contoso.com' -Confirm:$false

        $r.CurrentGroupName | Should -Be 'OnPrem-Scope'
        ($r.Warnings -join ';') | Should -Match 'managed on-premises'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-DistributionGroupMember -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
    }

    It 'MailEnabledSecurityGroup: errors when -AccessGroupName is omitted' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -Confirm:$false
        ($r.Errors -join ';') | Should -Match 'AccessGroupName is required'
    }

    It 'MailEnabledSecurityGroup: errors (never creates) when the referenced group does not exist' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'Missing-Scope' -Confirm:$false

        ($r.Errors -join ';') | Should -Match 'cannot be created'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 0
    }

    It 'MailEnabledSecurityGroup: rejects -NewGroupPrefix' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -NewGroupPrefix 'Um365Prod' -Confirm:$false
        ($r.Errors -join ';') | Should -Match 'cannot be used with'
    }

    It 'MailEnabledSecurityGroup: warns that -ManagedBy and -BootstrapMember are ignored when set to non-default values' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -ManagedBy 'custom-owner@contoso.com' -BootstrapMember 'custom-bootstrap@contoso.com' -Confirm:$false
        ($r.Warnings -join ';') | Should -Match 'ManagedBy was ignored'
        ($r.Warnings -join ';') | Should -Match 'BootstrapMember was ignored'
    }
}
