#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-MgContext { }
    function global:Get-MgServicePrincipal { [CmdletBinding()] param([string]$Filter, [string]$ServicePrincipalId) }
    function global:Get-ManagementRoleAssignment { [CmdletBinding()] param([string]$Role, [string]$Identity) }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Get-DistributionGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }

    # Contoso's assignments use the real shape confirmed against a live tenant for the 'Group'
    # write-scope (what -RecipientGroupScope actually produces): CustomRecipientWriteScope is
    # EMPTY, and the scope group name has to be recovered from CustomResourceScope (the name of an
    # auto-created ManagementScope object, format "<GroupName>_<GUID>"). Fabrikam uses the
    # (unaffected, still-correct) CustomRecipientScope write-scope, where CustomRecipientWriteScope
    # holds the group identity directly.
    $script:Assignments = @(
        [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' }
        [pscustomobject]@{ Name = 'AppCldR-Contoso'; Role = 'Application Calendars.Read'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' }
        [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $false; RecipientWriteScope = 'CustomRecipientScope'; CustomRecipientWriteScope = 'UDLRAo1-Fabrikam' }
        [pscustomobject]@{ Name = 'AppMailSend-Helpdesk'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Helpdesk'; RoleAssigneeType = 'RoleGroup'; Enabled = $true }
    )
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-MgContext','Get-MgServicePrincipal','Get-ManagementRoleAssignment','Get-UnifiedGroup','Get-UnifiedGroupLinks','Get-DistributionGroup','Get-DistributionGroupMember') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RegisteredAppWithPermission' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'admin@contoso.com' } }

        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            $script:Assignments | Where-Object { -not $Role -or $_.Role -eq $Role }
        }

        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            switch ($Filter) {
                "displayName eq 'Contoso_SP'" { @() ; break }
                "displayName eq 'Contoso'" {
                    [pscustomobject]@{
                        DisplayName = 'Contoso'
                        AppId       = '11111111-1111-1111-1111-111111111111'
                        Id          = '22222222-2222-2222-2222-222222222222'
                    }
                    break
                }
                "displayName eq 'Fabrikam_SP'" { @() ; break }
                "displayName eq 'Fabrikam'" {
                    [pscustomobject]@{
                        DisplayName = 'Fabrikam'
                        AppId       = '33333333-3333-3333-3333-333333333333'
                        Id          = '44444444-4444-4444-4444-444444444444'
                    }
                    break
                }
                default { @() }
            }
        }

        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup {
            if ($Identity -eq 'Um365RAo1-Contoso') { [pscustomobject]@{ DisplayName = 'Um365RAo1-Contoso'; Identity = $Identity } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks {
            @([pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' })
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1-Fabrikam') { [pscustomobject]@{ DisplayName = 'UDLRAo1-Fabrikam'; Identity = $Identity } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @([pscustomobject]@{ PrimarySmtpAddress = 'dl-member@fabrikam.com'; Name = 'dl-member' })
        }
    }

    It 'returns one row per distinct registered application' {
        $r = Get-RegisteredAppWithPermission

        $r.Count | Should -Be 2
        ($r.DisplayName | Sort-Object) | Should -Be @('Contoso', 'Fabrikam')
        ($r | Where-Object DisplayName -eq 'Contoso').Roles | Should -Be @('Application Calendars.Read', 'Application Mail.Send')
    }

    It 'resolves the scope group name and membership for an M365Group-scoped app' {
        $r = Get-RegisteredAppWithPermission

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.ScopeGroupNames | Should -Be @('Um365RAo1-Contoso')
        $contoso.ScopeGroupMembers | Should -Contain 'shared@contoso.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroupLinks -Times 1 -ParameterFilter { $Identity -eq 'Um365RAo1-Contoso' }
    }

    It 'resolves the scope group name and membership for a DistributionList-scoped app' {
        $r = Get-RegisteredAppWithPermission

        $fabrikam = $r | Where-Object DisplayName -eq 'Fabrikam'
        $fabrikam.ScopeGroupNames | Should -Be @('UDLRAo1-Fabrikam')
        $fabrikam.ScopeGroupMembers | Should -Contain 'dl-member@fabrikam.com'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-DistributionGroupMember -Times 1
    }

    It 'strips the GUID suffix from CustomResourceScope to recover the real group name' {
        $r = Get-RegisteredAppWithPermission

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.ScopeGroupNames | Should -Be @('Um365RAo1-Contoso')
    }

    It 'caches scope group membership so a group shared by two applications is only read once' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Shared_20d5848c-4d61-4b82-a44f-205adc37321f' }
                [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1-Shared_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
            ) | Where-Object { -not $Role -or $_.Role -eq $Role }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { [pscustomobject]@{ DisplayName = 'Um365RAo1-Shared'; Identity = $Identity } }

        $null = Get-RegisteredAppWithPermission

        # Two different assignments (different apps, different CustomResourceScope GUIDs) resolve
        # to the SAME group name "Um365RAo1-Shared" - its membership is still only read once.
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-UnifiedGroupLinks -Times 1
    }

    It 'falls back to the raw CustomResourceScope value when it does not match the GroupName-underscore-GUID pattern, and warns when that cannot be resolved either' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; Enabled = $true; RecipientWriteScope = 'Group'; CustomRecipientWriteScope = $null; CustomResourceScope = 'SomeCustomScopeNoGuidSuffix' }
            ) | Where-Object { -not $Role -or $_.Role -eq $Role }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }

        $warnings = $null
        $r = Get-RegisteredAppWithPermission -WarningVariable warnings -WarningAction SilentlyContinue

        $contoso = $r | Where-Object DisplayName -eq 'Contoso'
        $contoso.ScopeGroupNames | Should -Be @('SomeCustomScopeNoGuidSuffix')
        $contoso.ScopeGroupMembers | Should -BeNullOrEmpty
        ($warnings -join ';') | Should -Match "Could not resolve scope group 'SomeCustomScopeNoGuidSuffix'"
    }

    It 'normalizes a short role filter before querying EXO' {
        $r = Get-RegisteredAppWithPermission -Role 'Mail.Send'

        $r.Count | Should -Be 2
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 1 -ParameterFilter { $Role -eq 'Application Mail.Send' }
    }

    It 'filters by enabled state after collecting assignments' {
        $r = Get-RegisteredAppWithPermission -Enabled $false

        $r.Count | Should -Be 1
        $r.DisplayName | Should -Be 'Fabrikam'
        $r.DisabledAssignmentCount | Should -Be 1
    }
}

Describe 'Get-RegisteredAppWithPermission without a Graph session' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            $script:Assignments | Where-Object { -not $Role -or $_.Role -eq $Role }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
    }

    It 'returns EXO-only rows and warns once when Get-MgContext returns nothing, without calling Get-MgServicePrincipal' {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { throw 'should not be called' }

        $warnings = $null
        $r = Get-RegisteredAppWithPermission -WarningVariable warnings -WarningAction SilentlyContinue

        $r.Count | Should -Be 2
        ($r | Where-Object DisplayName -eq 'Contoso').AppId | Should -BeNullOrEmpty
        ($r | Where-Object DisplayName -eq 'Contoso').ServicePrincipalId | Should -BeNullOrEmpty
        ($warnings -join ';') | Should -Match 'Microsoft Graph is not connected'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 0
    }

    It 'returns EXO-only rows when Get-MgContext throws (Microsoft.Graph not imported)' {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { throw 'The term ''Get-MgContext'' is not recognized...' }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { throw 'should not be called' }

        $r = Get-RegisteredAppWithPermission -WarningAction SilentlyContinue

        $r.Count | Should -Be 2
        ($r.DisplayName | Sort-Object) | Should -Be @('Contoso', 'Fabrikam')
    }

    It 'falls back to EXO-only details for the rest of the run if Graph connectivity is lost mid-resolution' {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1' } }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { throw 'Authentication needed. Please call Connect-MgGraph.' }

        $warnings = $null
        $r = Get-RegisteredAppWithPermission -WarningVariable warnings -WarningAction SilentlyContinue

        $r.Count | Should -Be 2
        ($r | Where-Object DisplayName -eq 'Contoso').AppId | Should -BeNullOrEmpty
        ($warnings -join ';') | Should -Match 'Lost Microsoft Graph connectivity'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 1
    }
}
