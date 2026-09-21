#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI
    # (where Microsoft.Graph / ExchangeOnlineManagement are not installed). Parameters the
    # code passes (e.g. -Role) must be declared so the mock can bind and filter on them.
    function global:Get-ServicePrincipal { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementRoleAssignment { [CmdletBinding()] param([string]$Role, [string]$Identity) }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Get-DistributionGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }

    # EffectiveUserName/App are raw Get-ManagementRoleAssignment fields Exchange Online leaves
    # blank/placeholder for application-role assignments; AppMailSend-Contoso carries non-blank
    # placeholder values here to prove they pass through Get-RBAC4AppEntry's output as-is.
    $script:Assignments = @(
        [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = 'scope'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Contoso'; EffectiveUserName = 'NT AUTHORITY\SYSTEM (Contoso_SP)'; App = 'Contoso_SP' }
        [pscustomobject]@{ Name = 'Mail Recipients-Admin'; Role = 'Mail Recipients'; RoleAssigneeName = 'Org Management'; RoleAssigneeType = 'RoleGroup'; CustomRecipientWriteScope = $null; RecipientWriteScope = 'Organization'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'Mail Recipients-Admin'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppCldR-Fabrikam'; Role = 'Application Calendars.Read'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = 'scope2'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $false; Guid = [guid]::NewGuid(); Identity = 'AppCldR-Fabrikam'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailR-Helpdesk'; Role = 'Application Mail.Read'; RoleAssigneeName = 'Helpdesk'; RoleAssigneeType = 'RoleGroup'; CustomRecipientWriteScope = 'scope3'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailR-Helpdesk'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'UDLRAo1P-Tailspin_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailboxSettings-Tailspin'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailWide-Northwind'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Northwind_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; RecipientWriteScope = 'Organization'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailWide-Northwind'; EffectiveUserName = $null; App = $null }
    )

    # EXO service principal pointers, keyed by their own DisplayName (the "_SP" form).
    $script:ExoServicePrincipals = @(
        [pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' }
        [pscustomobject]@{ DisplayName = 'Fabrikam_SP'; AppId = '33333333-3333-3333-3333-333333333333'; ObjectId = '44444444-4444-4444-4444-444444444444' }
        [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = '66666666-6666-6666-6666-666666666666' }
    )
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ServicePrincipal','Get-ManagementRoleAssignment','Get-UnifiedGroup','Get-UnifiedGroupLinks','Get-DistributionGroup','Get-DistributionGroupMember') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RBAC4AppEntry (no filter)' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:Assignments }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1P-Tailspin') { [pscustomobject]@{ DisplayName = 'UDLRAo1P-Tailspin'; Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @([pscustomobject]@{ PrimarySmtpAddress = 'shared@tailspin.com'; Name = 'shared' })
        }
    }

    It 'returns only ServicePrincipal application-role assignments by default' {
        $r = Get-RBAC4AppEntry
        $r.Count | Should -Be 3
        ($r.Role | Sort-Object -Unique) | Should -Be @('Application Calendars.Read', 'Application Mail.Send', 'Application MailboxSettings.Read')
        ($r.RoleAssigneeType | Sort-Object -Unique) | Should -Be @('ServicePrincipal')
        ($r.RecipientScope | Sort-Object -Unique) | Should -Be @('CustomRecipientScope', 'Group')
    }

    It 'excludes application assignments outside group or custom recipient scopes' {
        $r = Get-RBAC4AppEntry
        $r.Name | Should -Not -Contain 'AppMailWide-Northwind'
        $r.RecipientScope | Should -Not -Contain 'Organization'
    }

    It 'projects the expected shape' {
        $r = Get-RBAC4AppEntry | Select-Object -First 1
        $r.PSObject.Properties.Name | Should -Be @('Name','Role','RoleAssigneeName','RoleAssigneeType','EffectiveUserName','App','DisplayName','AppId','ServicePrincipalId','Scope','ScopeGroupType','ScopeMembers','RecipientScope','Enabled','Guid','Identity')
    }

    It 'passes EffectiveUserName/App through from the raw assignment as-is' {
        $r = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailSend-Contoso'
        $r.EffectiveUserName | Should -Be 'NT AUTHORITY\SYSTEM (Contoso_SP)'
        $r.App | Should -Be 'Contoso_SP'

        $tailspin = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailboxSettings-Tailspin'
        $tailspin.EffectiveUserName | Should -BeNullOrEmpty
        $tailspin.App | Should -BeNullOrEmpty
    }

    It 'resolves Scope from CustomResourceScope for Group-scoped assignments' {
        $r = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailboxSettings-Tailspin'
        $r.Scope | Should -Be 'UDLRAo1P-Tailspin'
    }

    It 'resolves the scope group type and membership for a Group-scoped assignment' {
        $r = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailboxSettings-Tailspin'
        $r.ScopeGroupType | Should -Be 'DistributionList'
        $r.ScopeMembers | Should -Contain 'shared@tailspin.com'
    }

    It 'resolves AppId/ServicePrincipalId/DisplayName from the EXO service principal pointer' {
        $r = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailSend-Contoso'
        $r.DisplayName | Should -Be 'Contoso'
        $r.AppId | Should -Be '11111111-1111-1111-1111-111111111111'
        $r.ServicePrincipalId | Should -Be '22222222-2222-2222-2222-222222222222'
    }
}

Describe 'Get-RBAC4AppEntry -ScopeType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:Assignments }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { }
    }

    It 'includes every recipient scope with -ScopeType All' {
        $r = Get-RBAC4AppEntry -ScopeType All
        $r.Name | Should -Contain 'AppMailWide-Northwind'
        ($r.RecipientScope | Sort-Object -Unique) | Should -Be @('CustomRecipientScope', 'Group', 'Organization')
    }

    It 'filters to a single explicit scope type' {
        $r = Get-RBAC4AppEntry -ScopeType 'Group'
        $r.Count | Should -Be 1
        $r.Name | Should -Be 'AppMailboxSettings-Tailspin'
    }
}

Describe 'Get-RBAC4AppEntry -Role' {
    It 'normalizes a short role and queries EXO with the full role name' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            $script:Assignments | Where-Object { $_.Role -eq $Role }
        } -ParameterFilter { $Role -eq 'Application Mail.Send' }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }

        $r = Get-RBAC4AppEntry -Role 'Mail.Send'
        $r.Role | Should -Be 'Application Mail.Send'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 1 -ParameterFilter { $Role -eq 'Application Mail.Send' }
    }
}

Describe 'Get-RBAC4AppEntry -RoleAssigneeType' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:Assignments }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
    }

    It 'returns every assignee type with -RoleAssigneeType All' {
        $r = Get-RBAC4AppEntry -RoleAssigneeType All
        $r.Count | Should -Be 4
        ($r.RoleAssigneeType | Sort-Object -Unique) | Should -Be @('RoleGroup', 'ServicePrincipal')
        ($r.RecipientScope | Sort-Object -Unique) | Should -Be @('CustomRecipientScope', 'Group')
    }

    It 'filters to a specific assignee type' {
        $r = Get-RBAC4AppEntry -RoleAssigneeType RoleGroup
        $r.Count | Should -Be 1
        $r.RoleAssigneeName | Should -Be 'Helpdesk'
    }
}

Describe 'Get-RBAC4AppEntry application filter' {
    It 'keeps only assignments matching the resolved service principal' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            @([pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' })
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:Assignments }

        $r = Get-RBAC4AppEntry -RegisteredAppName 'Contoso'
        $r.Count | Should -Be 1
        $r.RoleAssigneeName | Should -Be 'Contoso_SP'
    }
}

Describe 'Get-RBAC4AppEntry -ByApplication' {
    BeforeEach {
        $script:AppAssignments = @(
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = 'NT AUTHORITY\SYSTEM (Contoso_SP)'; App = 'Contoso_SP' }
            [pscustomobject]@{ Name = 'AppCldR-Contoso'; Role = 'Application Calendars.Read'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = 'NT AUTHORITY\SYSTEM (Contoso_SP)'; App = 'Contoso_SP' }
            [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $false; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = 'UDLRAo1-Fabrikam'; EffectiveUserName = $null; App = $null }
            [pscustomobject]@{ Name = 'AppMailSend-Helpdesk'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Helpdesk'; RoleAssigneeType = 'RoleGroup'; Enabled = $true; EffectiveUserName = $null; App = $null }
        )

        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            param($Role)
            $script:AppAssignments | Where-Object { -not $Role -or $_.Role -eq $Role }
        }

        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }

        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup {
            if ($Identity -eq 'Um365RAo1-Contoso') { [pscustomobject]@{ DisplayName = 'Um365RAo1-Contoso'; Identity = $Identity } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks {
            @([pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' })
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1-Fabrikam') { [pscustomobject]@{ DisplayName = 'UDLRAo1-Fabrikam'; Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @([pscustomobject]@{ PrimarySmtpAddress = 'dl-member@fabrikam.com'; Name = 'dl-member' })
        }
    }

    It 'returns one row per distinct registered application' {
        $r = Get-RBAC4AppEntry -ByApplication

        $r.Count | Should -Be 2
        ($r.DisplayName | Sort-Object) | Should -Be @('Contoso', 'Fabrikam')
        ($r | Where-Object DisplayName -eq 'Contoso').Roles | Should -Be @('Application Calendars.Read', 'Application Mail.Send')
    }

    It 'aggregates non-blank EffectiveUserName/App values across an application''s assignments' {
        $r = Get-RBAC4AppEntry -ByApplication

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.EffectiveUserNames | Should -Be @('NT AUTHORITY\SYSTEM (Contoso_SP)')
        $contoso.Apps | Should -Be @('Contoso_SP')

        $fabrikam = $r | Where-Object DisplayName -eq 'Fabrikam'
        $fabrikam.EffectiveUserNames | Should -BeNullOrEmpty
        $fabrikam.Apps | Should -BeNullOrEmpty
    }

    It 'resolves AppId/ServicePrincipalId from the EXO service principal pointer, with the "_SP" suffix stripped from DisplayName' {
        $r = Get-RBAC4AppEntry -ByApplication

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.AppId | Should -Be '11111111-1111-1111-1111-111111111111'
        $contoso.ServicePrincipalId | Should -Be '22222222-2222-2222-2222-222222222222'
        $contoso.ExoServicePrincipal | Should -Be 'Contoso_SP'
    }

    It 'resolves the scope group name and membership for an M365Group-scoped app' {
        $r = Get-RBAC4AppEntry -ByApplication

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.ScopeGroupNames | Should -Be @('Um365RAo1-Contoso')
        $contoso.ScopeGroupMembers | Should -Contain 'shared@contoso.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroupLinks -Times 1 -ParameterFilter { $Identity -eq 'Um365RAo1-Contoso' }
    }

    It 'resolves the scope group name and membership for a DistributionList-scoped app' {
        $r = Get-RBAC4AppEntry -ByApplication

        $fabrikam = $r | Where-Object DisplayName -eq 'Fabrikam'
        $fabrikam.ScopeGroupNames | Should -Be @('UDLRAo1-Fabrikam')
        $fabrikam.ScopeGroupMembers | Should -Contain 'dl-member@fabrikam.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-DistributionGroupMember -Times 1
    }

    It 'caches scope group membership so a group shared by two applications is only read once' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            param($Role)
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Shared_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = $null; App = $null }
                [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Shared_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; EffectiveUserName = $null; App = $null }
            ) | Where-Object { -not $Role -or $_.Role -eq $Role }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Shared'; Identity = $Identity } }

        $null = Get-RBAC4AppEntry -ByApplication

        # Two different assignments (different apps, different CustomResourceScope GUIDs) resolve
        # to the SAME group name "Um365RAo1-Shared" - its membership is still only read once.
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroupLinks -Times 1
    }

    It 'falls back to the raw CustomResourceScope value when it does not match the GroupName-underscore-GUID pattern, and warns when that cannot be resolved either' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            param($Role)
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'SomeCustomScopeNoGuidSuffix'; EffectiveUserName = $null; App = $null }
            ) | Where-Object { -not $Role -or $_.Role -eq $Role }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }

        $warnings = $null
        $r = Get-RBAC4AppEntry -ByApplication -WarningVariable warnings -WarningAction SilentlyContinue

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.ScopeGroupNames | Should -Be @('SomeCustomScopeNoGuidSuffix')
        $contoso.ScopeGroupMembers | Should -BeNullOrEmpty
        ($warnings -join ';') | Should -Match "Could not resolve scope group 'SomeCustomScopeNoGuidSuffix'"
    }

    It 'normalizes a short role filter before querying EXO' {
        $r = Get-RBAC4AppEntry -ByApplication -Role 'Mail.Send'

        $r.Count | Should -Be 2
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 1 -ParameterFilter { $Role -eq 'Application Mail.Send' }
    }

    It 'filters by enabled state after collecting assignments' {
        $r = Get-RBAC4AppEntry -ByApplication -Enabled $false

        $r.Count | Should -Be 1
        $r.DisplayName | Should -Be 'Fabrikam'
        $r.DisabledAssignmentCount | Should -Be 1
    }
}

Describe 'Get-RBAC4AppEntry -ByApplication with an unresolvable EXO service principal' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = $null; App = $null }
                [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $false; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = 'UDLRAo1-Fabrikam'; EffectiveUserName = $null; App = $null }
            )
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
    }

    It 'returns EXO-only rows and warns once per unresolvable assignee, without needing Microsoft Graph' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }

        $warnings = $null
        $r = Get-RBAC4AppEntry -ByApplication -WarningVariable warnings -WarningAction SilentlyContinue

        $r.Count | Should -Be 2
        ($r | Where-Object DisplayName -eq 'Contoso').AppId | Should -BeNullOrEmpty
        ($r | Where-Object DisplayName -eq 'Contoso').ServicePrincipalId | Should -BeNullOrEmpty
        ($r | Where-Object DisplayName -eq 'Contoso').DisplayName | Should -Be 'Contoso'
        ($warnings -join ';') | Should -Match "Could not resolve EXO assignee 'Contoso_SP'"
    }
}
