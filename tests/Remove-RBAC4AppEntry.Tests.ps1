#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI
    # (where ExchangeOnlineManagement is not installed). Parameters the code passes must be
    # declared so the mock can bind and filter on them. No Microsoft Graph stubs are needed: SP
    # resolution goes through Get-ServicePrincipal (EXO) only.
    function global:Get-ConnectionInformation { [CmdletBinding()] param() }
    function global:Get-ServicePrincipal { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementRoleAssignment { [CmdletBinding()] param([string]$Role, [string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Remove-ManagementRoleAssignment { [CmdletBinding(SupportsShouldProcess)] param([string]$Identity) }
    function global:Remove-UnifiedGroup { [CmdletBinding(SupportsShouldProcess)] param([string]$Identity) }
    function global:Get-Recipient { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }
    function global:Remove-DistributionGroup { [CmdletBinding(SupportsShouldProcess)] param([string]$Identity) }
    function global:Get-ManagementScope { [CmdletBinding()] param([string]$Identity) }
    function global:Remove-ManagementScope { [CmdletBinding(SupportsShouldProcess)] param([string]$Identity) }

    $script:ExoSp = [pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ConnectionInformation','Get-ServicePrincipal','Get-UnifiedGroup','Get-ManagementRoleAssignment','Get-UnifiedGroupLinks','Remove-ManagementRoleAssignment','Remove-UnifiedGroup','Get-Recipient','Get-DistributionGroup','Get-DistributionGroupMember','Remove-DistributionGroup','Get-ManagementScope','Remove-ManagementScope') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Remove-RBAC4AppEntry' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Contoso'; Identity = 'Um365RAo1-Contoso' } }
        # One own assignment scoped to the group.
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{
                Name                      = 'AppMailSend-Contoso'
                Role                      = 'Application Mail.Send'
                RoleAssigneeName          = 'Contoso_SP'
                RecipientWriteScope       = 'Group'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'
            })
        }
        # Only the bootstrap placeholder member.
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @([pscustomobject]@{ PrimarySmtpAddress = $null; Name = 'GraphAPI-Dummy' }) }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = 'MSRAo1P-Contoso'; RecipientFilter = "MemberOfGroup -eq 'CN=g,DC=prod'" } }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementScope { }
    }

    It 'removes own assignments, the management scope and the group when clean' {
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeTrue
        $r.ScopeGroupName | Should -Be 'Um365RAo1-Contoso'
        $r.OwnAssignments | Should -Be @('AppMailSend-Contoso')
        $r.ForeignAssignments | Should -BeNullOrEmpty
        $r.AssignmentsRemoved | Should -Be @('AppMailSend-Contoso')
        $r.GroupRemoved | Should -BeTrue
        $r.ManagementScopeName | Should -Be 'MSRAo1P-Contoso'
        $r.ManagementScopeExisted | Should -BeTrue
        $r.ManagementScopeRemoved | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementScope -Times 1 -ParameterFilter { $Identity -eq 'MSRAo1P-Contoso' }
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 1
    }

    It 'removes an assignment bound to the management scope (-CustomResourceScope)' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso' })
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeTrue
        $r.AssignmentsRemoved | Should -Be @('AppMailSend-Contoso')
        $r.ManagementScopeRemoved | Should -BeTrue
    }

    It 'aborts when a foreign assignment is bound to the management scope' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso' },
                [pscustomobject]@{ Name = 'AppMailRead-Other'; Role = 'Application Mail.Read'; RoleAssigneeName = 'OtherApp_SP'; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso' }
            )
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.ForeignAssignments | Should -Be @('AppMailRead-Other')
        $r.Reason | Should -Match 'MSRAo1P-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementScope -Times 0
    }

    It 'tears down a -ScopeKind Recipients setup without touching any group' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso' })
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -ScopeKind Recipients -Confirm:$false

        $r.IsRemoved | Should -BeTrue
        $r.ScopeGroupName | Should -BeNullOrEmpty
        $r.ManagementScopeRemoved | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement Get-UnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'aborts when a foreign assignment is scoped to the group' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' },
                [pscustomobject]@{ Name = 'AppMailRead-Other'; Role = 'Application Mail.Read'; RoleAssigneeName = 'OtherApp_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
            )
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.Reason | Should -Not -BeNullOrEmpty
        $r.ForeignAssignments | Should -Be @('AppMailRead-Other')
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'does not treat wildcard characters in the app display name as assignment-match wildcards' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            @([pscustomobject]@{ DisplayName = '*_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' })
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Star'; Role = 'Application Mail.Send'; RoleAssigneeName = '*_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Wildcard-Scope_20d5848c-4d61-4b82-a44f-205adc37321f' },
                [pscustomobject]@{ Name = 'AppMailRead-Other'; Role = 'Application Mail.Read'; RoleAssigneeName = 'OtherApp_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Wildcard-Scope_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
            )
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName '*' -AccessGroupType M365Group -AccessGroupName 'Wildcard-Scope' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.OwnAssignments | Should -Be @('AppMailSend-Star')
        $r.ForeignAssignments | Should -Be @('AppMailRead-Other')
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'treats an assignee whose name merely contains the app name as foreign (exact match, no substring)' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            @(
                $script:ExoSp,
                [pscustomobject]@{ DisplayName = 'ContosoArchiver_SP'; AppId = '33333333-3333-3333-3333-333333333333'; ObjectId = '44444444-4444-4444-4444-444444444444' }
            )
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' },
                [pscustomobject]@{ Name = 'AppMailRead-ContosoArchiver'; Role = 'Application Mail.Read'; RoleAssigneeName = 'ContosoArchiver_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
            )
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.OwnAssignments | Should -Be @('AppMailSend-Contoso')
        $r.ForeignAssignments | Should -Be @('AppMailRead-ContosoArchiver')
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'treats an assignment bound by the service principal object id as own' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = '22222222-2222-2222-2222-222222222222'; RoleAssigneeType = 'ServicePrincipal'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' })
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeTrue
        $r.OwnAssignments | Should -Be @('AppMailSend-Contoso')
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 1
    }

    It 'treats an unresolvable assignee that only embeds the AppId in its name as foreign' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{ Name = 'AppMailSend-Legacy'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Legacy-11111111-1111-1111-1111-111111111111'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' })
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.ForeignAssignments | Should -Be @('AppMailSend-Legacy')
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
    }

    It 'aborts when the group has a real member beyond the bootstrap dummy' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks {
            @(
                [pscustomobject]@{ PrimarySmtpAddress = $null; Name = 'GraphAPI-Dummy' },
                [pscustomobject]@{ PrimarySmtpAddress = 'real@contoso.com'; Name = 'real' }
            )
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.RealMembers | Should -Be @('real@contoso.com')
        $r.Reason | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'treats a group with only the bootstrap member as clean' {
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.RealMembers | Should -BeNullOrEmpty
        $r.IsRemoved | Should -BeTrue
    }

    It 'performs no removals under -WhatIf' {
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -WhatIf

        $r.IsRemoved | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'reports ScopeGroupExisted false when the group is already gone' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.ScopeGroupExisted | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'records an error and is not removed when the service principal cannot be resolved' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }

        $r = Remove-RBAC4AppEntry -AppId '33333333-3333-3333-3333-333333333333' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.Errors.Count | Should -BeGreaterThan 0
    }
}

Describe 'Remove-RBAC4AppEntry -AccessGroupType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{
                Name                      = 'AppMailSend-Contoso'
                Role                      = 'Application Mail.Send'
                RoleAssigneeName          = 'Contoso_SP'
                RecipientWriteScope       = 'Group'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'OnPrem-Scope_20d5848c-4d61-4b82-a44f-205adc37321f'
            })
        }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Remove-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { throw 'not found' }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementScope { }
    }

    It 'MailEnabledSecurityGroup: detaches assignments but never deletes the group, even with a foreign assignment' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ RecipientTypeDetails = 'MailUniversalSecurityGroup'; DisplayName = 'OnPrem-Scope'; ManagedBy = @() } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'OnPrem-Scope_20d5848c-4d61-4b82-a44f-205adc37321f' },
                [pscustomobject]@{ Name = 'AppMailRead-Other'; Role = 'Application Mail.Read'; RoleAssigneeName = 'OtherApp_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'OnPrem-Scope_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
            )
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -Confirm:$false

        $r.AccessGroupType | Should -Be 'MailEnabledSecurityGroup'
        $r.AssignmentsRemoved | Should -Be @('AppMailSend-Contoso')
        $r.GroupRemoved | Should -BeFalse
        $r.Reason | Should -Match 'left in place'
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-DistributionGroup -Times 0
    }

    It 'MailEnabledSecurityGroup: leaves the management scope in place while a foreign assignment uses it' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ RecipientTypeDetails = 'MailUniversalSecurityGroup'; DisplayName = 'OnPrem-Scope'; ManagedBy = @() } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = 'MSRAo1P-Contoso' } }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso' },
                [pscustomobject]@{ Name = 'AppMailRead-Other'; Role = 'Application Mail.Read'; RoleAssigneeName = 'OtherApp_SP'; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso' }
            )
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -AccessGroupName 'OnPrem-Scope' -Confirm:$false

        $r.AssignmentsRemoved | Should -Be @('AppMailSend-Contoso')
        $r.ManagementScopeRemoved | Should -BeFalse
        ($r.Warnings -join ';') | Should -Match 'still used'
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementScope -Times 0
    }

    It 'DistributionList: removes the group with Remove-DistributionGroup, not Remove-UnifiedGroup' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Contoso'; Identity = 'Um365RAo1-Contoso' } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @([pscustomobject]@{ PrimarySmtpAddress = $null; Name = 'GraphAPI-Dummy' }) }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'UDLRAo1P-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' })
        }

        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType DistributionList -Confirm:$false

        $r.IsRemoved | Should -BeTrue
        $r.GroupRemoved | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-DistributionGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'throws (terminating) when -ManagementScopeName is combined with -ManagementScopePrefix' {
        { Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -ManagementScopeName 'a' -ManagementScopePrefix 'b' -Confirm:$false } |
            Should -Throw '*cannot be used together*'
    }
}

Describe 'Remove-RBAC4AppEntry validation and failure paths' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { [pscustomobject]@{ TenantId = 'tenant-1'; UserPrincipalName = 'admin@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @($script:ExoSp) }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Contoso'; Identity = 'Um365RAo1-Contoso' } }
        # One own assignment scoped to the group.
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @([pscustomobject]@{
                Name                      = 'AppMailSend-Contoso'
                Role                      = 'Application Mail.Send'
                RoleAssigneeName          = 'Contoso_SP'
                RecipientWriteScope       = 'Group'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'
            })
        }
        # Only the bootstrap placeholder member.
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { @([pscustomobject]@{ PrimarySmtpAddress = $null; Name = 'GraphAPI-Dummy' }) }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { }
        Mock -ModuleName EXORBACforAppManagement Remove-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = 'MSRAo1P-Contoso'; RecipientFilter = "MemberOfGroup -eq 'CN=g,DC=prod'" } }
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementScope { }
    }

    It 'records an error for MailEnabledSecurityGroup without -AccessGroupName' {
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -Confirm:$false
        ($r.Errors -join ';') | Should -Match '-AccessGroupName is required'
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
    }

    It 'still runs when the tenant id cannot be read' {
        Mock -ModuleName EXORBACforAppManagement Get-ConnectionInformation { throw 'not connected' }
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false
        $r.TenantId | Should -BeNullOrEmpty
        $r.IsRemoved | Should -BeTrue
    }

    It 'reports a failed role assignment removal and leaves the management scope and group in place' {
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment { throw 'denied' }
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        ($r.Errors -join ';') | Should -Match "Failed to remove role assignment 'AppMailSend-Contoso': denied"
        ($r.Warnings -join ';') | Should -Match "Management scope 'MSRAo1P-Contoso' was left in place because removing role assignments failed"
        $r.ManagementScopeRemoved | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementScope -Times 0
    }

    It 'reports a failed management scope removal' {
        Mock -ModuleName EXORBACforAppManagement Remove-ManagementScope { throw 'scope busy' }
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.ManagementScopeRemoved | Should -BeFalse
        ($r.Errors -join ';') | Should -Match "Failed to remove management scope 'MSRAo1P-Contoso': scope busy"
    }

    It 'reports a failed group removal' {
        Mock -ModuleName EXORBACforAppManagement Remove-UnifiedGroup { throw 'group locked' }
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        $r.IsRemoved | Should -BeFalse
        $r.GroupRemoved | Should -BeFalse
        ($r.Errors -join ';') | Should -Match "Failed to remove M365Group 'Um365RAo1-Contoso': group locked"
    }

    It 'fails closed (removes nothing) when the role assignment read fails' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { throw 'throttled' }
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false -WarningAction SilentlyContinue

        $r.IsRemoved | Should -BeFalse
        $r.Reason | Should -Match 'Safety check could not be completed'
        ($r.Errors -join ';') | Should -Match 'Failed to read role assignments: throttled'
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'fails closed (removes nothing) when the group member read fails' {
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { throw 'member read failed' }
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false -WarningAction SilentlyContinue

        $r.IsRemoved | Should -BeFalse
        $r.Reason | Should -Match "reading members of 'Um365RAo1-Contoso' failed"
        ($r.Errors -join ';') | Should -Match 'member read failed'
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementScope -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-UnifiedGroup -Times 0
    }

    It 'records an error (not "not found") when the service principal read fails' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { throw 'EXO unavailable' }
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false

        ($r.Errors -join ';') | Should -Match 'EXO unavailable'
        Should -Invoke -ModuleName EXORBACforAppManagement Remove-ManagementRoleAssignment -Times 0
    }

    It '-FailOnError emits the summary and writes an error record when Errors is non-empty' {
        Mock -ModuleName EXORBACforAppManagement Remove-UnifiedGroup { throw 'group locked' }
        $errs = $null
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false -FailOnError -ErrorVariable errs -ErrorAction SilentlyContinue

        $r | Should -Not -BeNullOrEmpty
        @($r).Count | Should -Be 1
        $r.GroupRemoved | Should -BeFalse
        # -ErrorVariable also collects errors suppressed inside the module; keep only ours.
        $failed = @($errs | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'RBAC4AppOperationFailed*' })
        $failed.Count | Should -Be 1
        $failed[0].Exception.Message | Should -Match 'group locked'
        $failed[0].TargetObject.GroupRemoved | Should -BeFalse
    }

    It '-FailOnError with -ErrorAction Stop terminates without double-recording the error' {
        Mock -ModuleName EXORBACforAppManagement Remove-UnifiedGroup { throw 'group locked' }
        $out = [System.Collections.Generic.List[object]]::new()
        { Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false -FailOnError -ErrorAction Stop | ForEach-Object { $out.Add($_) } } |
            Should -Throw -ExpectedMessage '*group locked*'
        $out.Count | Should -Be 1
        @($out[0].Errors).Count | Should -Be 1
    }

    It '-FailOnError writes no error record on success' {
        $errs = $null
        $r = Remove-RBAC4AppEntry -RegisteredAppName 'Contoso' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1' -Confirm:$false -FailOnError -ErrorVariable errs

        $r.IsRemoved | Should -BeTrue
        @($errs | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'RBAC4AppOperationFailed*' }) | Should -BeNullOrEmpty
    }
}
