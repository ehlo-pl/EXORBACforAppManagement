#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-ServicePrincipal { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementRoleAssignment { [CmdletBinding()] param([string]$Role, [string]$Identity) }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Get-DistributionGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementScope { [CmdletBinding()] param([string]$Identity) }
    function global:Get-Recipient { [CmdletBinding()] param([string]$Identity, [string]$RecipientPreviewFilter, [string]$Anr, $ResultSize) }

    $script:ExoServicePrincipals = @(
        [pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' }
        [pscustomobject]@{ DisplayName = 'Fabrikam_SP'; AppId = '33333333-3333-3333-3333-333333333333'; ObjectId = '44444444-4444-4444-4444-444444444444' }
        [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = '66666666-6666-6666-6666-666666666666' }
    )
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ServicePrincipal', 'Get-ManagementRoleAssignment', 'Get-UnifiedGroup', 'Get-UnifiedGroupLinks', 'Get-DistributionGroup', 'Get-DistributionGroupMember', 'Get-ManagementScope', 'Get-Recipient') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RBAC4AppApplication' {
    BeforeEach {
        $script:AppAssignments = @(
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = 'NT AUTHORITY\SYSTEM (Contoso_SP)'; App = 'Contoso_SP' }
            [pscustomobject]@{ Name = 'AppCldR-Contoso'; Role = 'Application Calendars.Read'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = 'NT AUTHORITY\SYSTEM (Contoso_SP)'; App = 'Contoso_SP' }
            [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $false; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'UDLRAo1-Fabrikam_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = $null; App = $null }
            [pscustomobject]@{ Name = 'AppMailSend-Helpdesk'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Helpdesk'; RoleAssigneeType = 'RoleGroup'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'UDLRAo1-Fabrikam_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = $null; App = $null }
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

    It 'returns one RBAC4App.Application row per distinct registered application' {
        $r = @(Get-RBAC4AppApplication)

        $r.Count | Should -Be 2
        $r[0].PSObject.TypeNames | Should -Contain 'RBAC4App.Application'
        ($r.DisplayName | Sort-Object) | Should -Be @('Contoso', 'Fabrikam')
        ($r | Where-Object DisplayName -eq 'Contoso').Roles | Should -Be @('Application Calendars.Read', 'Application Mail.Send')
        ($r | Where-Object DisplayName -eq 'Contoso').AssignmentCount | Should -Be 2
    }

    It 'projects the expected shape' {
        $r = Get-RBAC4AppApplication | Select-Object -First 1
        $r.PSObject.Properties.Name | Should -Be @('DisplayName', 'AppId', 'ServicePrincipalId', 'ExoServicePrincipal', 'RoleAssigneeType', 'ManagementScopeNames', 'ScopeKinds', 'ScopeGroupNames', 'ScopeGroupMembers', 'Roles', 'RoleAssignmentNames', 'EffectiveUserNames', 'Apps', 'AssignmentCount', 'EnabledAssignmentCount', 'DisabledAssignmentCount', 'Warnings')
    }

    It 'groups piped Get-RBAC4AppEntry rows without reading Exchange Online again' {
        $rows = @(Get-RBAC4AppEntry)
        $r = @($rows | Get-RBAC4AppApplication)

        $r.Count | Should -Be 2
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 1 -Exactly
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ServicePrincipal -Times 1 -Exactly
    }

    It 'aggregates non-blank EffectiveUserName/App values across an application''s assignments' {
        $r = Get-RBAC4AppApplication

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.EffectiveUserNames | Should -Be @('NT AUTHORITY\SYSTEM (Contoso_SP)')
        $contoso.Apps | Should -Be @('Contoso_SP')

        $fabrikam = $r | Where-Object DisplayName -eq 'Fabrikam'
        $fabrikam.EffectiveUserNames | Should -BeNullOrEmpty
        $fabrikam.Apps | Should -BeNullOrEmpty
    }

    It 'resolves AppId/ServicePrincipalId from the EXO service principal pointer, with the "_SP" suffix stripped from DisplayName' {
        $contoso = Get-RBAC4AppApplication | Where-Object DisplayName -eq 'Contoso'
        $contoso.AppId | Should -Be '11111111-1111-1111-1111-111111111111'
        $contoso.ServicePrincipalId | Should -Be '22222222-2222-2222-2222-222222222222'
        $contoso.ExoServicePrincipal | Should -Be 'Contoso_SP'
        $contoso.RoleAssigneeType | Should -Be 'ServicePrincipal'
    }

    It 'resolves the scope group name and membership for an M365Group-scoped app' {
        $contoso = Get-RBAC4AppApplication | Where-Object DisplayName -eq 'Contoso'
        $contoso.ScopeGroupNames | Should -Be @('Um365RAo1-Contoso')
        $contoso.ScopeGroupMembers | Should -Contain 'shared@contoso.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroupLinks -Times 1 -ParameterFilter { $Identity -eq 'Um365RAo1-Contoso' }
    }

    It 'resolves the scope group name and membership for a DistributionList-scoped app' {
        $fabrikam = Get-RBAC4AppApplication | Where-Object DisplayName -eq 'Fabrikam'
        $fabrikam.ScopeGroupNames | Should -Be @('UDLRAo1-Fabrikam')
        $fabrikam.ScopeGroupMembers | Should -Contain 'dl-member@fabrikam.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-DistributionGroupMember -Times 1
    }

    It 'caches scope group membership so a group shared by two applications is only read once' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Shared_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = $null; App = $null }
                [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Shared_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; EffectiveUserName = $null; App = $null }
            )
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Shared'; Identity = $Identity } }

        $null = Get-RBAC4AppApplication

        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroupLinks -Times 1
    }

    It 'falls back to the raw CustomResourceScope value when it does not match the GroupName-underscore-GUID pattern, and warns when that cannot be resolved either' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'SomeCustomScopeNoGuidSuffix'; EffectiveUserName = $null; App = $null }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }

        $warnings = $null
        $contoso = Get-RBAC4AppApplication -WarningVariable warnings -WarningAction SilentlyContinue | Where-Object DisplayName -eq 'Contoso'

        $contoso.ScopeGroupNames | Should -Be @('SomeCustomScopeNoGuidSuffix')
        $contoso.ScopeGroupMembers | Should -BeNullOrEmpty
        ($warnings -join ';') | Should -Match "Could not resolve scope group 'SomeCustomScopeNoGuidSuffix'"
        ($contoso.Warnings -join ';') | Should -Match "Could not resolve scope group 'SomeCustomScopeNoGuidSuffix'"
    }

    It 'normalizes a short role filter before querying EXO' {
        $r = @(Get-RBAC4AppApplication -Role 'Mail.Send')

        $r.Count | Should -Be 2
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 1 -ParameterFilter { $Role -eq 'Application Mail.Send' }
    }

    It 'filters by enabled state' {
        $r = @(Get-RBAC4AppApplication -Enabled $false)

        $r.Count | Should -Be 1
        $r.DisplayName | Should -Be 'Fabrikam'
        $r.DisabledAssignmentCount | Should -Be 1
    }

    It 'self-fetches one application by name, AppId, or service principal object id' -TestCases @(
        @{ Splat = @{ RegisteredAppName = 'Contoso' } }
        @{ Splat = @{ AppId = '11111111-1111-1111-1111-111111111111' } }
        @{ Splat = @{ SpObjectId = '22222222-2222-2222-2222-222222222222' } }
    ) {
        param($Splat)
        $r = @(Get-RBAC4AppApplication @Splat)
        $r.Count | Should -Be 1
        $r[0].DisplayName | Should -Be 'Contoso'
    }

    It 'keeps a role group apart from applications and gives it no DisplayName (F6)' {
        $r = @(Get-RBAC4AppApplication -RoleAssigneeType All)

        $r.Count | Should -Be 3
        $helpdesk = $r | Where-Object ExoServicePrincipal -eq 'Helpdesk'
        $helpdesk.RoleAssigneeType | Should -Be 'RoleGroup'
        $helpdesk.DisplayName | Should -BeNullOrEmpty
        $helpdesk.AppId | Should -BeNullOrEmpty
    }
}

Describe 'Get-RBAC4AppApplication with an unresolvable EXO service principal' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = $null; App = $null }
                [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $false; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'UDLRAo1-Fabrikam_20d5848c-4d61-4b82-a44f-205adc37321f'; EffectiveUserName = $null; App = $null }
            )
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { @() }
    }

    It 'returns EXO-only rows and warns once per unresolvable assignee, without needing Microsoft Graph' {
        $warnings = $null
        $r = @(Get-RBAC4AppApplication -WarningVariable warnings -WarningAction SilentlyContinue)

        $r.Count | Should -Be 2
        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.AppId | Should -BeNullOrEmpty
        $contoso.ServicePrincipalId | Should -BeNullOrEmpty
        @($warnings | Where-Object { "$_" -match "Could not resolve EXO assignee 'Contoso_SP'" }).Count | Should -Be 1
    }
}

Describe 'Get-RBAC4AppApplication aggregation (private ConvertTo-RBAC4AppApplicationRow)' {
    It 'warns when the rows of one assignee disagree on ServicePrincipalId' {
        $rows = foreach ($id in 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') {
            [pscustomobject]@{
                PSTypeName = 'RBAC4App.Entry'; Name = "App-$id"; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'
                EffectiveUserName = $id; App = $null; DisplayName = 'Tailspin'; AppId = '55555555-5555-5555-5555-555555555555'; ServicePrincipalId = $id
                ManagementScope = $null; ScopeKind = 'GroupDirect'; ScopeGroupName = 'G'; ScopeMembers = @(); Enabled = $true; Warnings = @()
            }
        }

        $warnings = @()
        $r = $rows | Get-RBAC4AppApplication -WarningVariable warnings -WarningAction SilentlyContinue

        $r.ServicePrincipalId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        ($warnings -join ';') | Should -Match 'different ServicePrincipalId values'
        ($r.Warnings -join ';') | Should -Match 'different ServicePrincipalId values'
    }
}

Describe 'Get-RBAC4AppApplication failure paths' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
    }

    It 'rejects objects that are not Get-RBAC4AppEntry rows' {
        $errors = @()
        $r = 'Contoso' | Get-RBAC4AppApplication -ErrorVariable errors -ErrorAction SilentlyContinue

        $r | Should -BeNullOrEmpty
        ($errors -join ';') | Should -Match 'accepts only Get-RBAC4AppEntry rows'
    }

    It 'passes through an unresolvable identity error from Get-RBAC4AppEntry' {
        $errors = @()
        $r = Get-RBAC4AppApplication -AppId '99999999-9999-9999-9999-999999999999' -ErrorVariable errors -ErrorAction SilentlyContinue

        $r | Should -BeNullOrEmpty
        ($errors -join ';') | Should -Match 'No Exchange Online service principal found'
    }

    It 'returns nothing for an empty tenant' {
        Get-RBAC4AppApplication | Should -BeNullOrEmpty
    }
}
