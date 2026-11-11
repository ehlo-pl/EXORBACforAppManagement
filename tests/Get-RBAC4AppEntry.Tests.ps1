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
    function global:Get-ManagementScope { [CmdletBinding()] param([string]$Identity) }
    function global:Get-Recipient { [CmdletBinding()] param([string]$Identity, [string]$RecipientPreviewFilter, [string]$Anr, $ResultSize) }

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
    foreach ($n in 'Get-ServicePrincipal','Get-ManagementRoleAssignment','Get-UnifiedGroup','Get-UnifiedGroupLinks','Get-DistributionGroup','Get-DistributionGroupMember','Get-ManagementScope','Get-Recipient') {
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
        $r.PSObject.Properties.Name | Should -Be @('Name','RoleAssignmentName','Role','RoleAssigneeName','RoleAssigneeType','EffectiveUserName','App','DisplayName','AppId','ServicePrincipalId','ServicePrincipalIdSource','Scope','ScopeSource','ManagementScope','ScopeKind','ScopeFilter','ScopeGroupName','ScopeGroupType','ScopeGroupResolved','ScopeMembers','RecipientScope','Enabled','Guid','Identity','Warnings','Errors')
        $r.PSObject.TypeNames | Should -Contain 'RBAC4App.Entry'
        $r.RoleAssignmentName | Should -Be $r.Name
    }

    It 'reports where ServicePrincipalId and the scope came from' {
        $tailspin = Get-RBAC4AppEntry -WarningAction SilentlyContinue | Where-Object Name -eq 'AppMailboxSettings-Tailspin'
        $tailspin.ServicePrincipalIdSource | Should -Be 'ExoPointer'
        $tailspin.ScopeSource | Should -Be 'Legacy'
        $tailspin.ScopeGroupName | Should -Be 'UDLRAo1P-Tailspin'
        $tailspin.ScopeGroupResolved | Should -BeTrue
        $tailspin.Warnings | Should -BeNullOrEmpty
        $tailspin.Errors | Should -BeNullOrEmpty
    }

    It 'reports an unreadable custom recipient scope on the row without probing it as a group' {
        $warnings = @()
        $contoso = Get-RBAC4AppEntry -WarningVariable warnings -WarningAction SilentlyContinue | Where-Object Name -eq 'AppMailSend-Contoso'
        $contoso.ScopeSource | Should -Be 'ManagementScope'
        $contoso.ManagementScope | Should -Be 'scope'
        $contoso.ScopeKind | Should -BeNullOrEmpty
        $contoso.ScopeGroupResolved | Should -BeFalse
        ($contoso.Warnings -join ';') | Should -Match "Could not read management scope 'scope'"
        @($warnings | Where-Object { "$_" -match "Could not read management scope 'scope'" }).Count | Should -Be 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-DistributionGroup -Times 0 -ParameterFilter { $Identity -eq 'scope' }
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

    It 'resolves an assignee whose RoleAssigneeName is the raw service principal object id (New-ManagementRoleAssignment -App ObjectId)' {
        # No angle brackets in the test name: Pester expands <name> as a data-driven template,
        # which fails under the build's Set-StrictMode -Version Latest.
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            $script:Assignments + [pscustomobject]@{
                Name = 'AppMailSend-Fabrikam-ByObjectId'; Role = 'Application Mail.Send'
                RoleAssigneeName = '44444444-4444-4444-4444-444444444444'; RoleAssigneeType = 'ServicePrincipal'
                CustomRecipientWriteScope = 'scope4'; RecipientWriteScope = 'CustomRecipientScope'
                Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Fabrikam-ByObjectId'
                EffectiveUserName = $null; App = $null
            }
        }

        $warnings = @()
        $r = Get-RBAC4AppEntry -WarningVariable warnings -WarningAction SilentlyContinue |
            Where-Object Name -eq 'AppMailSend-Fabrikam-ByObjectId'

        $r.DisplayName | Should -Be 'Fabrikam'
        $r.AppId | Should -Be '33333333-3333-3333-3333-333333333333'
        $r.ServicePrincipalId | Should -Be '44444444-4444-4444-4444-444444444444'
        ($warnings -join ';') | Should -Not -Match 'Could not resolve EXO assignee'
    }

    It 'resolves a scope group via Get-Recipient -Anr when Get-UnifiedGroup and Get-DistributionGroup miss it' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailR-Renamed'; Role = 'Application Mail.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'Um365RAo1-Renamed_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true }
        }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            @(
                [pscustomobject]@{ Name = 'someone'; DisplayName = 'Um365RAo1-Renamed owner'; RecipientTypeDetails = 'UserMailbox'; Guid = 'u1' }
                [pscustomobject]@{ Name = 'Um365RAo1-Renamed_abc'; DisplayName = 'Um365RAo1-Renamed'; Alias = 'renamed'; RecipientTypeDetails = 'GroupMailbox'; Guid = 'g1' }
            )
        } -ParameterFilter { $Anr -eq 'Um365RAo1-Renamed' }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks {
            @([pscustomobject]@{ PrimarySmtpAddress = 'alice@tailspin.com' })
        } -ParameterFilter { $Identity -eq 'g1' }

        $warn = @()
        $row = Get-RBAC4AppEntry -WarningVariable warn -WarningAction SilentlyContinue

        $row.ScopeGroupType | Should -Be 'M365Group'
        @($row.ScopeMembers) | Should -Be @('alice@tailspin.com')
        (@($warn | ForEach-Object { "$_" }) -join ';') | Should -Not -Match 'Could not resolve scope group'
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

Describe 'Get-RBAC4AppEntry empty ServicePrincipalId fallback to EffectiveUserName' {
    BeforeEach {
        $script:FallbackGuid = 'abcdef01-2345-6789-abcd-ef0123456789'
        # The EXO pointer resolves by name but comes back without an ObjectId.
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = '' }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'UDLRAo1P-Tailspin_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true; EffectiveUserName = $script:FallbackGuid; App = $null }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1P-Tailspin') { [pscustomobject]@{ DisplayName = $Identity; Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @([pscustomobject]@{ PrimarySmtpAddress = 'shared@tailspin.com'; Name = 'shared' })
        }
    }

    It 'fills ServicePrincipalId from a GUID EffectiveUserName and warns once' {
        $warn = @()
        $r = Get-RBAC4AppEntry -WarningVariable warn -WarningAction SilentlyContinue

        $r.ServicePrincipalId | Should -Be $script:FallbackGuid
        $r.AppId | Should -Be '55555555-5555-5555-5555-555555555555'
        @($warn | Where-Object { "$_" -match 'from EffectiveUserName' }).Count | Should -Be 1
    }

    It 'extracts the GUID when EffectiveUserName wraps it in other text' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'UDLRAo1P-Tailspin_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true; EffectiveUserName = "ServicePrincipal ($($script:FallbackGuid))"; App = $null }
        }
        (Get-RBAC4AppEntry -WarningAction SilentlyContinue).ServicePrincipalId | Should -Be $script:FallbackGuid
    }

    It 'leaves ServicePrincipalId empty with a warning when EffectiveUserName holds no GUID' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'UDLRAo1P-Tailspin_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true; EffectiveUserName = 'NT AUTHORITY\SYSTEM (Tailspin_SP)'; App = $null }
        }
        $warn = @()
        $r = Get-RBAC4AppEntry -WarningVariable warn -WarningAction SilentlyContinue

        $r.ServicePrincipalId | Should -BeNullOrEmpty
        ($warn -join ';') | Should -Match 'holds no object id'
    }
}

Describe 'Get-RBAC4AppEntry management scope resolution' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            @(
                [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Contoso' }
                [pscustomobject]@{ Name = 'AppMailRead-Contoso'; Role = 'Application Mail.Read'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailRead-Contoso' }
                [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Fabrikam'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Fabrikam' }
                [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Tailspin'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Tailspin' }
            )
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope {
            switch ($Identity) {
                'MSRAo1P-Contoso'  { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(MemberOfGroup -eq 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod')" } }
                'MSRAo1P-Fabrikam' { [pscustomobject]@{ Name = $Identity; RecipientFilter = "((PrimarySmtpAddress -eq 'bob@fabrikam.com') -or (PrimarySmtpAddress -eq 'alice@fabrikam.com'))" } }
                'MSRAo1P-Tailspin' { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(CustomAttribute5 -eq 'TailspinApp')" } }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            if ($PesterBoundParameters.ContainsKey('RecipientPreviewFilter')) {
                @([pscustomobject]@{ PrimarySmtpAddress = 'tagged@tailspin.com'; Name = 'tagged' })
            }
            elseif ($Identity -eq 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod') {
                [pscustomobject]@{ Name = 'UDLRAo1P-Contoso'; DisplayName = 'UDLRAo1P-Contoso' }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1P-Contoso') { [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { @([pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' }) }
    }

    It 'resolves a Group-kind management scope to its group, type and members' {
        $r = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailSend-Contoso'
        $r.ManagementScope | Should -Be 'MSRAo1P-Contoso'
        $r.ScopeKind | Should -Be 'Group'
        $r.Scope | Should -Be 'UDLRAo1P-Contoso'
        $r.ScopeGroupType | Should -Be 'DistributionList'
        $r.ScopeMembers | Should -Be @('shared@contoso.com')
    }

    It 'reads a Recipients-kind scope members straight from the filter' {
        $r = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailSend-Fabrikam'
        $r.ScopeKind | Should -Be 'Recipients'
        $r.Scope | Should -Be 'MSRAo1P-Fabrikam'
        $r.ScopeGroupType | Should -BeNullOrEmpty
        $r.ScopeMembers | Should -Be @('alice@fabrikam.com', 'bob@fabrikam.com')
    }

    It 'previews a Tag-kind scope via Get-Recipient -RecipientPreviewFilter' {
        $r = Get-RBAC4AppEntry | Where-Object Name -eq 'AppMailSend-Tailspin'
        $r.ScopeKind | Should -Be 'Tag'
        $r.ScopeFilter | Should -Be "(CustomAttribute5 -eq 'TailspinApp')"
        $r.ScopeMembers | Should -Be @('tagged@tailspin.com')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-Recipient -ParameterFilter { $RecipientPreviewFilter -eq "(CustomAttribute5 -eq 'TailspinApp')" -and $ResultSize -eq 1000 } -Times 1
    }

    It 'reads each distinct management scope only once' {
        $null = Get-RBAC4AppEntry
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementScope -ParameterFilter { $Identity -eq 'MSRAo1P-Contoso' } -Times 1 -Exactly
    }

    It 'reports management scope names and kinds per application via Get-RBAC4AppApplication' {
        $contoso = Get-RBAC4AppEntry | Get-RBAC4AppApplication | Where-Object DisplayName -eq 'Contoso'
        $contoso.ManagementScopeNames | Should -Be @('MSRAo1P-Contoso')
        $contoso.ScopeKinds | Should -Be @('Group')
        $contoso.ScopeGroupNames | Should -Be @('UDLRAo1P-Contoso')
        $contoso.ScopeGroupMembers | Should -Be @('shared@contoso.com')
    }

    It 'reports a legacy group-scoped assignment as ScopeKind GroupDirect' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'UDLRAo1P-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Contoso' }
        }
        $r = Get-RBAC4AppEntry
        $r.ScopeKind | Should -Be 'GroupDirect'
        $r.ManagementScope | Should -BeNullOrEmpty
        $r.Scope | Should -Be 'UDLRAo1P-Contoso'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementScope -Times 0
    }
}

Describe 'Get-RBAC4AppEntry validation and failure paths' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:Assignments }
    }

    It 'resolves the application by -SpObjectId' {
        $r = @(Get-RBAC4AppEntry -SpObjectId '22222222-2222-2222-2222-222222222222')
        $r.Count | Should -Be 1
        $r[0].RoleAssigneeName | Should -Be 'Contoso_SP'
    }

    It 'reports an unresolvable piped identity and still processes the next one' {
        $err = @()
        $r = @('Nope', 'Contoso' | Get-RBAC4AppEntry -ErrorVariable err -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
        $r.Name | Should -Be @('AppMailSend-Contoso')
        ($err -join ';') | Should -Match "matching 'Nope'"
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ServicePrincipal -Times 1 -Exactly
    }

    It 'writes an error for an ambiguous application name' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            [pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' }
            [pscustomobject]@{ DisplayName = 'Contoso'; AppId = '77777777-7777-7777-7777-777777777777'; ObjectId = '88888888-8888-8888-8888-888888888888' }
        }
        $err = @()
        $r = Get-RBAC4AppEntry -RegisteredAppName 'Contoso' -ErrorVariable err -ErrorAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($err -join ';') | Should -Match 'Ambiguous'
    }

    It 'reports a failed read once per call and does not retry for later pipeline items' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { throw 'boom' }
        $err = @()
        $r = 'Contoso', 'Fabrikam' | Get-RBAC4AppEntry -ErrorVariable err -ErrorAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        @($err | Where-Object { "$_" -match 'Failed to read the management role assignments' }).Count | Should -Be 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 1 -Exactly
    }

    It 'does not accept -ScopeType values outside RecipientWriteScopeType' {
        { Get-RBAC4AppEntry -ScopeType 'Everything' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'writes an error and returns nothing when the application cannot be resolved' {
        $r = Get-RBAC4AppEntry -AppId '99999999-9999-9999-9999-999999999999' -ErrorVariable err -ErrorAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($err -join ';') | Should -Match 'No Exchange Online service principal found'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 0
    }
}
