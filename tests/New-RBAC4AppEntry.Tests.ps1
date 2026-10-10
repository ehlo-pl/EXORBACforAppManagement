#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs for the external EXO cmdlets so Pester can mock them in the module scope
    # without the real ExchangeOnlineManagement module installed. They must be global so the
    # module's session state (a child of global) can resolve them. No Microsoft Graph stubs are
    # needed: SP resolution goes through Get-ServicePrincipal (EXO) only.
    function global:Get-ConnectionInformation { }
    function global:Get-UnifiedGroup { }
    function global:Get-UnifiedGroupLinks { }
    function global:New-UnifiedGroup { }
    function global:Set-UnifiedGroup { }
    function global:Add-UnifiedGroupLinks { }
    function global:New-ServicePrincipal { }
    function global:Get-ServicePrincipal { }
    function global:Get-Recipient { param($Identity, $RecipientPreviewFilter, $ResultSize) }
    function global:New-ManagementRoleAssignment { param($App, $Role, $CustomResourceScope, $RecipientGroupScope, $Name) }
    function global:Get-ManagementRoleAssignment { }
    function global:Get-DistributionGroupMember { }
    function global:Add-DistributionGroupMember { }
    function global:Get-DistributionGroup { }
    function global:Get-ManagementScope { param($Identity) }
    function global:New-ManagementScope { param($Name, $RecipientRestrictionFilter) }
    function global:Set-ManagementScope { param($Identity, $RecipientRestrictionFilter) }

    # Shape returned by Get-ServicePrincipal (EXO): the pointer's own DisplayName carries the
    # "_SP" suffix and the object id property is ObjectId (not Id).
    $script:ExoSp = [pscustomobject]@{
        DisplayName = 'Contoso_SP'
        AppId       = '11111111-1111-1111-1111-111111111111'
        ObjectId    = '22222222-2222-2222-2222-222222222222'
    }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ConnectionInformation','Get-UnifiedGroup','Get-UnifiedGroupLinks','New-UnifiedGroup','Set-UnifiedGroup','Add-UnifiedGroupLinks','New-ServicePrincipal','Get-ServicePrincipal','Get-Recipient','New-ManagementRoleAssignment','Get-ManagementRoleAssignment','Get-DistributionGroupMember','Add-DistributionGroupMember','Get-DistributionGroup','Get-ManagementScope','New-ManagementScope','Set-ManagementScope') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppEntry SP resolution' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter } }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementScope { }
    }

    It 'throws when none of -RegisteredAppName, -AppId, or -SpObjectId is supplied' {
        { New-RBAC4AppEntry -WhatIf } | Should -Throw '*must be supplied*'
    }

    It 'records an error when no EXO service principal matches the AppId and there is not enough information to register one' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }

        $r = New-RBAC4AppEntry -AppId '33333333-3333-3333-3333-333333333333' -WhatIf
        $r.Errors -join ';' | Should -Match 'not enough information to register one'
    }

    It 'records an error when the display name is ambiguous' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            @(
                [pscustomobject]@{ DisplayName = 'dup_SP'; AppId = '66666666-6666-6666-6666-666666666666'; ObjectId = '77777777-7777-7777-7777-777777777777' },
                [pscustomobject]@{ DisplayName = 'dup_SP'; AppId = '88888888-8888-8888-8888-888888888888'; ObjectId = '99999999-9999-9999-9999-999999999999' }
            )
        }

        $r = New-RBAC4AppEntry -RegisteredAppName 'dup' -WhatIf
        $r.Errors -join ';' | Should -Match 'Ambiguous'
    }

    It 'bootstraps a never-before-registered service principal when AppId, SpObjectId, and RegisteredAppName are all supplied' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup {
            [pscustomobject]@{ OwnerRequested = @('owner@contoso.com'); OwnerAdded = @('owner@contoso.com'); Group = [pscustomobject]@{ DistinguishedName = 'CN=g,OU=contoso,DC=prod' } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = 'g'; ManagedBy = @() } }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }
        Mock -ModuleName EXORBACforAppManagement Register-EXOServicePrincipal { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Export-Clixml { }

        $r = New-RBAC4AppEntry -RegisteredAppName 'NewApp' -AppId '44444444-4444-4444-4444-444444444444' -SpObjectId '55555555-5555-5555-5555-555555555555' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.Errors | Should -BeNullOrEmpty
        $r.ResolvedDisplay | Should -Be 'NewApp'
        $r.AppId | Should -Be '44444444-4444-4444-4444-444444444444'
        $r.SpObjectId | Should -Be '55555555-5555-5555-5555-555555555555'
    }
}

Describe 'New-RBAC4AppEntry -WhatIf' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter } }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup {
            [pscustomobject]@{ OwnerRequested = @('owner@contoso.com'); OwnerAdded = @('owner@contoso.com'); Group = [pscustomobject]@{ DistinguishedName = 'CN=g,OU=contoso,DC=prod' } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = 'g'; ManagedBy = @() } }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement New-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Add-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement New-ServicePrincipal { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Export-Clixml { }
    }

    It 'normalizes the role and builds the assignment name' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Members 'shared@contoso.com' -Role 'Mail.Send' -WhatIf
        $r.RolesNormalized | Should -Contain 'Application Mail.Send'
        $r.RoleAssignmentsName[0] | Should -BeLike 'AppMailSend-*'
    }

    It 'reports the requested and added Unified Group owner' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -ManagedBy 'owner@contoso.com' -Role 'Mail.Send' -WhatIf
        $r.PSObject.Properties.Name | Should -Contain 'OwnerRequested'
        $r.PSObject.Properties.Name | Should -Contain 'OwnerAdded'
        $r.OwnerRequested | Should -Be @('owner@contoso.com')
    }

    It 'passes multiple -ManagedBy owners through to New-RBAC4AppUnifiedGroup' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -ManagedBy 'owner1@contoso.com', 'owner2@contoso.com' -Role 'Mail.Send' -WhatIf
        $r.Errors | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 1 -ParameterFilter {
            (Compare-Object $ManagedBy @('owner1@contoso.com', 'owner2@contoso.com')).Count -eq 0
        }
    }

    It 'passes ChangeReference through to the scope group helper' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -ChangeReference 'CHG123456' -Role 'Mail.Send' -WhatIf
        $r.ChangeReference | Should -Be 'CHG123456'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppUnifiedGroup -Times 1 -ParameterFilter {
            $ChangeReference -eq 'CHG123456'
        }
    }

    It 'uses AccessGroupName as the Unified Group scope' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -AccessGroupName 'RBAC-AppScope-Contoso' -Role 'Mail.Send' -WhatIf

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
        $null = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-UnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ServicePrincipal -Times 0
    }

    It 'reports the pre-existing and newly-added members in MembersFinal' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @([pscustomobject]@{ PrimarySmtpAddress = 'existing@contoso.com'; Name = 'existing' }) }

        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Members 'shared@contoso.com' -Role 'Mail.Send' -Confirm:$false

        $r.MembersFinal | Should -Contain 'existing@contoso.com'
        $r.MembersFinal | Should -Contain 'shared@contoso.com'
    }

    It 'skips creating a role assignment that already exists and is scoped to the target management scope' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso' }
        }

        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.RoleAssignments | Should -HaveCount 1
        ($r.Warnings -join ';') | Should -Match "already exists and is scoped to management scope 'MSRAo1P-Contoso'"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'warns and suggests Set-RBAC4AppEntry when an assignment is still scoped directly to the group (legacy)' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' }
        }

        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.Errors | Should -BeNullOrEmpty
        ($r.Warnings -join ';') | Should -Match 'legacy -RecipientGroupScope'
        ($r.Warnings -join ';') | Should -Match 'Set-RBAC4AppEntry'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'warns instead of erroring when a same-named assignment exists but is scoped elsewhere' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'SomeOtherGroup_20d5848c-4d61-4b82-a44f-205adc37321f' }
        }

        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.Errors | Should -BeNullOrEmpty
        ($r.Warnings -join ';') | Should -Match "scoped to 'SomeOtherGroup', not management scope 'MSRAo1P-Contoso'"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'records an error when a same-named assignment exists for a different role' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{
                Name                      = 'AppMailSend-Contoso'
                Role                      = 'Application Calendars.Read'
                RecipientWriteScope       = 'Group'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'
            }
        }

        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppDistributionGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); Group = [pscustomobject]@{ DistinguishedName = 'CN=g,OU=contoso,DC=prod' } } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -Confirm:$false

        ($r.Errors -join ';') | Should -Match "bound to role 'Application Calendars.Read', not 'Application Mail.Send'"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }
}

Describe 'New-RBAC4AppEntry -AccessGroupType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter } }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o') } }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppDistributionGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); Group = [pscustomobject]@{ Name = 'g'; DistinguishedName = 'CN=g,OU=contoso,DC=prod' } } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; DisplayName = 'mesg'; ManagedBy = @(); DistinguishedName = 'CN=OnPrem-Scope,OU=contoso,DC=prod' } }
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

Describe 'New-RBAC4AppEntry management scope' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter } }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppDistributionGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); Group = [pscustomobject]@{ Name = 'UDLRAo1P-Contoso'; DistinguishedName = "CN=UDLRAo1P-Contoso,OU=contoso,DC=prod" } } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        Mock -ModuleName EXORBACforAppManagement Add-DistributionGroupMember { }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = "$Identity" } }
        Mock -ModuleName EXORBACforAppManagement Register-EXOServicePrincipal { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { [pscustomobject]@{ Name = $Name } }
        Mock -ModuleName EXORBACforAppManagement Export-Clixml { }
    }

    It 'Group (default): creates a MemberOfGroup management scope and assigns with -CustomResourceScope' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -Confirm:$false

        $r.Errors | Should -BeNullOrEmpty
        $r.ScopeKind | Should -Be 'Group'
        $r.ManagementScopeName | Should -Be 'MSRAo1P-Contoso'
        $r.ManagementScopeFilter | Should -Be "MemberOfGroup -eq 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod'"
        $r.ManagementScopeCreated | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 1 -ParameterFilter {
            $Name -eq 'MSRAo1P-Contoso' -and $RecipientRestrictionFilter -eq "MemberOfGroup -eq 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod'"
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1 -ParameterFilter {
            $CustomResourceScope -eq 'MSRAo1P-Contoso' -and -not $RecipientGroupScope
        }
    }

    It 'Recipients: builds a PrimarySmtpAddress filter and never touches a group' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Recipients -ScopeRecipients 'b@contoso.com', 'a@contoso.com' -Role 'Mail.Send' -Confirm:$false

        $r.Errors | Should -BeNullOrEmpty
        $r.ScopeGroupName | Should -BeNullOrEmpty
        $r.AccessGroupType | Should -BeNullOrEmpty
        $r.ManagementScopeFilter | Should -Be "(PrimarySmtpAddress -eq 'a@contoso.com') -or (PrimarySmtpAddress -eq 'b@contoso.com')"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-DistributionGroupMember -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1 -ParameterFilter { $CustomResourceScope -eq 'MSRAo1P-Contoso' }
    }

    It 'Recipients: warns that explicitly supplied group parameters are ignored' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Recipients -ScopeRecipients 'a@contoso.com' -Members 'x@contoso.com' -Role 'Mail.Send' -Confirm:$false
        ($r.Warnings -join ';') | Should -Match '-Members only applies to -ScopeKind Group'
    }

    It 'Recipients: records an error when -ScopeRecipients is missing' {
        { New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Recipients -Role 'Mail.Send' -Confirm:$false } | Should -Throw '*ScopeRecipients is required*'
    }

    It 'Tag: builds a CustomAttribute filter defaulting the value to the scope name' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Tag -ScopeTagAttribute CustomAttribute7 -Role 'Mail.Send' -Confirm:$false
        $r.ManagementScopeFilter | Should -Be "CustomAttribute7 -eq 'MSRAo1P-Contoso'"
    }

    It 'Filter: passes a raw filter through and honours -ManagementScopeName' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Filter -ScopeFilter "Department -eq 'Sales'" -ManagementScopeName 'Sales-Scope' -Role 'Mail.Send' -Confirm:$false
        $r.ManagementScopeName | Should -Be 'Sales-Scope'
        $r.ManagementScopeFilter | Should -Be "Department -eq 'Sales'"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1 -ParameterFilter { $CustomResourceScope -eq 'Sales-Scope' }
    }

    It 'leaves an existing scope with a different filter unchanged and warns' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = 'MSRAo1P-Contoso'; RecipientFilter = "CustomAttribute1 -eq 'old'" } }
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Tag -ScopeTagValue 'new' -Role 'Mail.Send' -Confirm:$false
        ($r.Warnings -join ';') | Should -Match 'different filter'
        $r.ManagementScopeCreated | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 0
    }

    It 'does not create the management scope under -WhatIf' {
        $r = New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Tag -Role 'Mail.Send' -WhatIf
        $r.ManagementScopeName | Should -Be 'MSRAo1P-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'throws when -ManagementScopeName and -ManagementScopePrefix are both set' {
        { New-RBAC4AppEntry -RegisteredAppName 'Contoso' -ManagementScopeName 'a' -ManagementScopePrefix 'b' -WhatIf } | Should -Throw '*cannot be used together*'
    }
}
