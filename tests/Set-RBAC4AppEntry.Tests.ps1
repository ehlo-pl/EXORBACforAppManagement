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
    function global:Set-UnifiedGroup { param([string]$Identity) }
    function global:Get-ServicePrincipal { param([string]$Identity) }
    function global:Get-Recipient { param([string]$Identity, $RecipientPreviewFilter, $ResultSize) }
    function global:Get-ManagementRoleAssignment { param([string]$Identity, [string]$Role) }
    function global:New-ManagementRoleAssignment { param($App, $Role, $RecipientGroupScope, $CustomResourceScope, $Name) }
    function global:Set-ManagementRoleAssignment { param($Identity, $CustomResourceScope, $RecipientGroupScope) }
    function global:Get-ManagementScope { param($Identity) }
    function global:New-ManagementScope { param($Name, $RecipientRestrictionFilter) }
    function global:Set-ManagementScope { param($Identity, $RecipientRestrictionFilter) }
    function global:Remove-ManagementRoleAssignment { param([string]$Identity) }
    function global:Get-DistributionGroup { param([string]$Identity) }
    function global:Set-DistributionGroup { param([string]$Identity, $RequireSenderAuthenticationEnabled, [string[]]$AcceptMessagesOnlyFromSendersOrMembers, [switch]$BypassSecurityGroupManagerCheck) }
    function global:Get-DistributionGroupMember { param([string]$Identity) }
    function global:Add-DistributionGroupMember { param([string]$Identity, [string]$Member, [switch]$BypassSecurityGroupManagerCheck) }

    $script:ExoSp = [pscustomobject]@{
        DisplayName = 'Contoso_SP'
        AppId       = '11111111-1111-1111-1111-111111111111'
        ObjectId    = '22222222-2222-2222-2222-222222222222'
    }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ConnectionInformation','Get-UnifiedGroup','Get-UnifiedGroupLinks','Add-UnifiedGroupLinks','Get-ServicePrincipal','Get-Recipient','Get-ManagementRoleAssignment','New-ManagementRoleAssignment','Remove-ManagementRoleAssignment','Get-DistributionGroup','Get-DistributionGroupMember','Add-DistributionGroupMember','Set-ManagementRoleAssignment','Get-ManagementScope','New-ManagementScope','Set-ManagementScope') {
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
        # Everything present by default: group exists, EXO SP exists, management scope exists pointing at
        # the current group, assignment exists bound to the management scope.
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = 'MSRAo1P-Contoso'; RecipientFilter = "MemberOfGroup -eq 'CN=Um365RAo1-Contoso,OU=contoso,DC=prod'" } }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter } }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = $Identity; DistinguishedName = "CN=$Identity,OU=contoso,DC=prod" } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111' }) }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = $Identity; Name = $Identity } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{
                Name                      = $Identity
                Role                      = 'Application Mail.Send'
                RecipientWriteScope       = 'CustomRecipientScope'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'MSRAo1P-Contoso'
            }
        }
        # Delegated module functions + mutating cmdlets.
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); AlreadyExisted = $false; Group = [pscustomobject]@{ Identity = $Name; DistinguishedName = "CN=$Name,OU=contoso,DC=prod" } } }
        Mock -ModuleName EXORBACforAppManagement Register-EXOServicePrincipal { [pscustomobject]@{ DisplayName = $DisplayName } }
        Mock -ModuleName EXORBACforAppManagement Add-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement Set-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Save-RBAC4AppChangeReferenceRecord { Join-Path $TestDrive "$ChangeReference.yaml" }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
    }

    It 'RecipientGroupScope (default): leaves an assignment bound directly to the group untouched' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' } }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.IsValid | Should -BeTrue
        $r.AssignmentScope | Should -Be 'RecipientGroupScope'
        $r.RoleAssignmentsUnchanged | Should -Contain 'AppMailSend-Contoso'
        $r.ManagementScopeName | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementRoleAssignment -Times 0
    }

    It 'RecipientGroupScope (default): re-binds a management-scoped assignment directly to the group' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.IsValid | Should -BeTrue
        $r.RoleAssignmentsRescoped | Should -Contain 'AppMailSend-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementRoleAssignment -Times 1 -ParameterFilter {
            $Identity -eq 'AppMailSend-Contoso' -and $RecipientGroupScope -eq 'Um365RAo1-Contoso' -and -not $CustomResourceScope
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 0
    }

    It 'RecipientGroupScope (default): creates a missing assignment bound directly to the group' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.RoleAssignmentsCreated | Should -Contain 'AppMailSend-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1 -ParameterFilter {
            $RecipientGroupScope -eq 'Um365RAo1-Contoso' -and -not $CustomResourceScope
        }
    }

    It 'RecipientGroupScope (default): moves the assignment to the new group on -NewGroupPrefix' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' } }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -NewGroupPrefix 'Um365Prod' -Role 'Mail.Send' -Confirm:$false

        $r.GroupChanged | Should -BeTrue
        $r.RoleAssignmentsRescoped | Should -Contain 'AppMailSend-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementRoleAssignment -Times 1 -ParameterFilter { $RecipientGroupScope -eq 'Um365Prod-Contoso' }
    }

    It 'leaves a fully-configured app on its group untouched and reports IsValid' {
        $r = Set-RBAC4AppEntry -AssignmentScope ManagementScope -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send'

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

    It 're-points the management scope at a new group when -NewGroupPrefix is supplied (assignments untouched)' {
        $r = Set-RBAC4AppEntry -AssignmentScope ManagementScope -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -NewGroupPrefix 'Um365Prod' -Confirm:$false

        $r.GroupChanged | Should -BeTrue
        $r.TargetGroupName | Should -Be 'Um365Prod-Contoso'
        $r.ManagementScopeUpdated | Should -BeTrue
        $r.ManagementScopeFilter | Should -Be "MemberOfGroup -eq 'CN=Um365Prod-Contoso,OU=contoso,DC=prod'"
        $r.RoleAssignmentsUnchanged | Should -Contain 'AppMailSend-Contoso'
        $r.IsValid | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 1 -ParameterFilter {
            $Identity -eq 'MSRAo1P-Contoso' -and $RecipientRestrictionFilter -eq "MemberOfGroup -eq 'CN=Um365Prod-Contoso,OU=contoso,DC=prod'"
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'migrates a legacy group-scoped assignment onto the management scope in place' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = $Identity; Role = 'Application Mail.Send'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' }
        }

        $r = Set-RBAC4AppEntry -AssignmentScope ManagementScope -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.ManagementScopeCreated | Should -BeTrue
        $r.RoleAssignmentsRescoped | Should -Contain 'AppMailSend-Contoso'
        $r.IsValid | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 1 -ParameterFilter {
            $RecipientRestrictionFilter -eq "MemberOfGroup -eq 'CN=Um365RAo1-Contoso,OU=contoso,DC=prod'"
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementRoleAssignment -Times 1 -ParameterFilter {
            $Identity -eq 'AppMailSend-Contoso' -and $CustomResourceScope -eq 'MSRAo1P-Contoso'
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 0
    }

    It 'falls back to remove + recreate when Set-ManagementRoleAssignment cannot re-scope' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = $Identity; Role = 'Application Mail.Send'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' }
        }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementRoleAssignment { throw 'not supported' }

        $r = Set-RBAC4AppEntry -AssignmentScope ManagementScope -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -Confirm:$false

        $r.Errors | Should -BeNullOrEmpty
        $r.RoleAssignmentsRescoped | Should -Contain 'AppMailSend-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 1 -ParameterFilter {
            $CustomResourceScope -eq 'MSRAo1P-Contoso' -and -not $RecipientGroupScope
        }
    }

    It 'switches to -ScopeKind Recipients by rewriting the scope filter, without touching a group' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Recipients -ScopeRecipients 'alice@contoso.com' -Role 'Mail.Send' -Confirm:$false

        $r.ScopeKind | Should -Be 'Recipients'
        $r.TargetGroupName | Should -BeNullOrEmpty
        $r.ManagementScopeUpdated | Should -BeTrue
        $r.IsValid | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 1 -ParameterFilter {
            $RecipientRestrictionFilter -eq "PrimarySmtpAddress -eq 'alice@contoso.com'"
        }
    }

    It 'stores ChangeReference for the existing target group in a local metadata file' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup {
            [pscustomobject]@{
                DisplayName = 'g'
                Identity    = $Identity
            }
        }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Role 'Mail.Send' -ChangeReference 'CHG123456' -Confirm:$false

        $r.ChangeReference | Should -Be 'CHG123456'
        $r.ChangeReferencePath | Should -Be (Join-Path $TestDrive 'CHG123456.yaml')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Save-RBAC4AppChangeReferenceRecord -Times 1 -ParameterFilter {
            $ChangeReference -eq 'CHG123456' -and $AccessGroupType -eq 'M365Group' -and $ScopeGroupName -eq 'Um365RAo1-Contoso'
        }
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
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-ManagementRoleAssignment -Times 0
    }
}

Describe 'Set-RBAC4AppEntry -AccessGroupType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ RecipientTypeDetails = 'MailUniversalSecurityGroup'; PrimarySmtpAddress = $Identity; Name = $Identity; DisplayName = $Identity; ManagedBy = @(); DistinguishedName = "CN=$Identity,OU=contoso,DC=prod" } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppDistributionGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); AlreadyExisted = $false; Group = [pscustomobject]@{ Identity = $Name; DistinguishedName = "CN=$Name,OU=contoso,DC=prod" } } }
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

    It 'CloudMailEnabledSecurityGroup: restricts an existing group that can still receive mail to its owner' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalSecurityGroup'; AcceptMessagesOnlyFromSendersOrMembers = @(); DistinguishedName = "CN=$Identity,OU=contoso,DC=prod" } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -Confirm:$false

        $r.AccessGroupType | Should -Be 'CloudMailEnabledSecurityGroup'
        $r.TargetGroupName | Should -Be 'USRACo1P-Contoso'
        $r.ScopeGroupExisted | Should -BeTrue
        $r.SendRestricted | Should -BeTrue
        $r.SendRestrictionApplied | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'USRACo1P-Contoso' -and $RequireSenderAuthenticationEnabled -eq $true -and $BypassSecurityGroupManagerCheck -and
            (@($AcceptMessagesOnlyFromSendersOrMembers) -join ',') -eq 'GraphAPI-Dummy-owner'
        }
    }

    It 'CloudMailEnabledSecurityGroup: leaves an already restricted group alone' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalSecurityGroup'; AcceptMessagesOnlyFromSendersOrMembers = @('GraphAPI-Dummy-owner'); DistinguishedName = "CN=$Identity,OU=contoso,DC=prod" } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -Confirm:$false

        $r.SendRestricted | Should -BeTrue
        $r.SendRestrictionApplied | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 0
    }

    It 'CloudMailEnabledSecurityGroup: changes nothing under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalSecurityGroup'; AcceptMessagesOnlyFromSendersOrMembers = @(); DistinguishedName = "CN=$Identity,OU=contoso,DC=prod" } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -WhatIf

        $r.SendRestricted | Should -BeFalse
        $r.SendRestrictionApplied | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 0
    }

    It 'HybridMailEnabledSecurityGroup: never applies a send restriction' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -Confirm:$false

        $r.SendRestricted | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 0
    }

    It 'HybridMailEnabledSecurityGroup: references an existing group and skips membership' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -Members 'new@contoso.com' -Confirm:$false

        $r.CurrentGroupName | Should -Be 'OnPrem-Scope'
        ($r.Warnings -join ';') | Should -Match 'managed on-premises'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-DistributionGroupMember -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Add-UnifiedGroupLinks -Times 0
    }

    It 'HybridMailEnabledSecurityGroup: errors when -AccessGroupName is omitted' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -Confirm:$false
        ($r.Errors -join ';') | Should -Match 'AccessGroupName is required'
    }

    It 'HybridMailEnabledSecurityGroup: errors (never creates) when the referenced group does not exist' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -AccessGroupName 'Missing-Scope' -Confirm:$false

        ($r.Errors -join ';') | Should -Match 'cannot be created'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppDistributionGroup -Times 0
    }

    It 'HybridMailEnabledSecurityGroup: records an error when the recipient is not a security group' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox'; DisplayName = $Identity } }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -AccessGroupName 'shared' -Confirm:$false

        ($r.Errors -join ';') | Should -Match "is of type 'SharedMailbox'"
        $r.IsValid | Should -BeFalse
    }

    It 'HybridMailEnabledSecurityGroup: rejects -NewGroupPrefix' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -NewGroupPrefix 'Um365Prod' -Confirm:$false
        ($r.Errors -join ';') | Should -Match 'cannot be used with'
    }

    It 'HybridMailEnabledSecurityGroup: warns that -ManagedBy and -BootstrapMember are ignored when set to non-default values' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -ManagedBy 'custom-owner@contoso.com' -BootstrapMember 'custom-bootstrap@contoso.com' -Confirm:$false
        ($r.Warnings -join ';') | Should -Match 'ManagedBy was ignored'
        ($r.Warnings -join ';') | Should -Match 'BootstrapMember was ignored'
    }
}

Describe 'Set-RBAC4AppEntry validation and failure paths' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        # Everything present by default: group exists, EXO SP exists, management scope exists pointing at
        # the current group, assignment exists bound to the management scope.
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = 'MSRAo1P-Contoso'; RecipientFilter = "MemberOfGroup -eq 'CN=Um365RAo1-Contoso,OU=contoso,DC=prod'" } }
        Mock -ModuleName EXORBACforAppManagement New-ManagementScope { [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter } }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementScope { }
        Mock -ModuleName EXORBACforAppManagement Set-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = $Identity; DistinguishedName = "CN=$Identity,OU=contoso,DC=prod" } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111' }) }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @() }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = $Identity; Name = $Identity } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{
                Name                      = $Identity
                Role                      = 'Application Mail.Send'
                RecipientWriteScope       = 'CustomRecipientScope'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'MSRAo1P-Contoso'
            }
        }
        # Delegated module functions + mutating cmdlets.
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppUnifiedGroup { [pscustomobject]@{ OwnerRequested = @('o'); OwnerAdded = @('o'); AlreadyExisted = $false; Group = [pscustomobject]@{ Identity = $Name; DistinguishedName = "CN=$Name,OU=contoso,DC=prod" } } }
        Mock -ModuleName EXORBACforAppManagement Register-EXOServicePrincipal { [pscustomobject]@{ DisplayName = $DisplayName } }
        Mock -ModuleName EXORBACforAppManagement Add-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement Set-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Save-RBAC4AppChangeReferenceRecord { Join-Path $TestDrive "$ChangeReference.yaml" }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
    }

    It 'throws for <Name>' -TestCases @(
        @{ Name = 'no identity';                         Splat = @{};                                                                         Message = '*must be supplied*' }
        @{ Name = 'scope name together with prefix';     Splat = @{ RegisteredAppName = 'Contoso'; ManagementScopeName = 'x'; ManagementScopePrefix = 'y' }; Message = '*cannot be used together*' }
        @{ Name = 'Recipients without -ScopeRecipients'; Splat = @{ RegisteredAppName = 'Contoso'; ScopeKind = 'Recipients' };               Message = '*-ScopeRecipients is required*' }
        @{ Name = 'Filter without -ScopeFilter';         Splat = @{ RegisteredAppName = 'Contoso'; ScopeKind = 'Filter' };                   Message = '*-ScopeFilter is required*' }
    ) {
        param($Splat, $Message)
        { Set-RBAC4AppEntry @Splat -Confirm:$false } | Should -Throw $Message
    }

    It 'warns that -ManagementScopeName is ignored with the default RecipientGroupScope' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -ManagementScopeName 'Custom' `
            -Confirm:$false -WarningAction SilentlyContinue
        ($r.Warnings -join ';') | Should -Match '-ManagementScopeName only applies to -AssignmentScope ManagementScope'
    }

    It 'still reconciles when Get-ConnectionInformation fails, warning that member filtering is skipped' {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { throw 'not connected' }
        $r = Set-RBAC4AppEntry -AssignmentScope ManagementScope -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' `
            -Members 'shared@contoso.com' -Confirm:$false -WarningAction SilentlyContinue

        $r.TenantId | Should -BeNullOrEmpty
        ($r.Warnings -join ';') | Should -Match 'connection user filtering will be skipped'
        $r.MembersAdded | Should -Contain 'shared@contoso.com'
    }

    It 'records an error and is not valid when the management scope cannot be reconciled' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { throw 'scope read failed' }
        $r = Set-RBAC4AppEntry -AssignmentScope ManagementScope -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsValid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match "Failed to reconcile management scope 'MSRAo1P-Contoso'"
    }

    It 'records an error and is not valid when a role assignment cannot be created' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { throw 'quota exceeded' }
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsValid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match "Failed to reconcile role assignment 'AppMailSend-Contoso' \(Application Mail.Send\): quota exceeded"
    }
}

Describe 'Set-RBAC4AppEntry pre-0.9.0 DistributionList guard' {
    BeforeAll {
        function global:Set-DistributionGroup { param([string]$Identity, $RequireSenderAuthenticationEnabled, [string[]]$AcceptMessagesOnlyFromSendersOrMembers, [switch]$BypassSecurityGroupManagerCheck) }
        function global:New-DistributionGroup { param($Name, $DisplayName, $Alias, $Type, $ManagedBy, $Members) }
    }

    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = $Identity; Name = $Identity; DistinguishedName = "CN=$Identity,DC=prod" } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @() }
        Mock -ModuleName EXORBACforAppManagement Add-DistributionGroupMember { }
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppScopeGroup { }
        Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'UDLRAo1P-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' })
        }
        # Only the pre-0.9.0 distribution list exists.
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1P-Contoso') { [pscustomobject]@{ Identity = $Identity; Name = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup'; AcceptMessagesOnlyFromSendersOrMembers = @('GraphAPI-Dummy-owner'); DistinguishedName = "CN=$Identity,DC=prod" } }
        }
    }

    It 'stops without changes when only the pre-0.9.0 UDLRAo1P list exists and the defaults are used' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -Confirm:$false

        $r.LegacyGroupName | Should -Be 'UDLRAo1P-Contoso'
        $r.CurrentGroupName | Should -Be 'USRACo1P-Contoso'
        ($r.Errors -join ';') | Should -Match "Scope group 'UDLRAo1P-Contoso' \(a DistributionList, the default before 0\.9\.0\) exists.*-AccessGroupType DistributionList"
        $r.IsValid | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppScopeGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
    }

    It 'reconciles the existing list with -AccessGroupType DistributionList' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -AccessGroupType DistributionList -Confirm:$false

        $r.LegacyGroupName | Should -BeNullOrEmpty
        $r.TargetGroupName | Should -Be 'UDLRAo1P-Contoso'
        ($r.Errors -join ';') | Should -Not -Match 'default before 0\.9\.0'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Remove-ManagementRoleAssignment -Times 0
    }

    It 'lets an explicit -AccessGroupType CloudMailEnabledSecurityGroup move the application' {
        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -AccessGroupType CloudMailEnabledSecurityGroup -Confirm:$false

        $r.LegacyGroupName | Should -BeNullOrEmpty
        ($r.Errors -join ';') | Should -Not -Match 'default before 0\.9\.0'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppScopeGroup -Times 1 -ParameterFilter { $Name -eq 'USRACo1P-Contoso' }
    }

    It 'does not apply once the USRACo1P group exists (application already moved)' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            [pscustomobject]@{ Identity = $Identity; Name = $Identity; RecipientTypeDetails = 'MailUniversalSecurityGroup'; AcceptMessagesOnlyFromSendersOrMembers = @('GraphAPI-Dummy-owner'); DistinguishedName = "CN=$Identity,DC=prod" }
        }

        $r = Set-RBAC4AppEntry -RegisteredAppName 'Contoso' -Role 'Mail.Send' -Confirm:$false

        $r.LegacyGroupName | Should -BeNullOrEmpty
        ($r.Errors -join ';') | Should -Not -Match 'default before 0\.9\.0'
    }
}
