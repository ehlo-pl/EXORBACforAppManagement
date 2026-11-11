#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs for the external cmdlets the function calls, declaring the parameters
    # it filters on so Mock -ModuleName can bind and intercept them.
    function global:Get-ApplicationAccessPolicy { [CmdletBinding()] param([string]$AppId) }
    function global:Get-MgServicePrincipal { [CmdletBinding()] param([string]$Filter, [string]$ServicePrincipalId) }
    function global:Get-MgServicePrincipalAppRoleAssignment { [CmdletBinding()] param([string]$ServicePrincipalId) }
    function global:Get-MgContext { [CmdletBinding()] param() }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ApplicationAccessPolicy','Get-MgServicePrincipal','Get-MgServicePrincipalAppRoleAssignment','Get-MgContext') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Convert-ApplicationAccessPolicyToRBAC' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy {
            [pscustomobject]@{
                AppId       = '11111111-1111-1111-1111-111111111111'
                AccessRight = 'RestrictAccess'
                ScopeName   = 'EvenUsers'
                Description = 'Restrict app to EvenUsers'
            }
        }

        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            # Pester only defines the parameter variable when it was bound on the call,
            # so Test-Path is the StrictMode-safe way to tell the two call shapes apart.
            if (Test-Path variable:ServicePrincipalId) {
                # Resource service principal (e.g. Microsoft Graph) AppRoles catalog.
                return [pscustomobject]@{
                    Id       = $ServicePrincipalId
                    AppRoles = @(
                        [pscustomobject]@{ Id = 'role-mailread'; Value = 'Mail.Read' }
                        [pscustomobject]@{ Id = 'role-ews';      Value = 'full_access_as_app' }
                        [pscustomobject]@{ Id = 'role-dir';      Value = 'Directory.Read.All' }
                    )
                }
            }
            # App service principal resolution by appId filter.
            [pscustomobject]@{
                DisplayName = 'Contoso'
                AppId       = '11111111-1111-1111-1111-111111111111'
                Id          = '22222222-2222-2222-2222-222222222222'
            }
        }

        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment {
            @(
                [pscustomobject]@{ AppRoleId = 'role-mailread'; ResourceId = '99999999-9999-9999-9999-999999999999' }
                [pscustomobject]@{ AppRoleId = 'role-ews';      ResourceId = '99999999-9999-9999-9999-999999999999' }
                [pscustomobject]@{ AppRoleId = 'role-dir';      ResourceId = '99999999-9999-9999-9999-999999999999' }
            )
        }

        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppEntry {
            [pscustomobject]@{ Warnings = @(); Errors = @() }
        }
        Mock -ModuleName EXORBACforAppManagement Get-MgContext {
            [pscustomobject]@{ TenantId = 'tenant-id-123' }
        }
    }

    It 'derives RBAC roles and writes YAML input without provisioning RBAC' {
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false

        $r.AppId | Should -Be '11111111-1111-1111-1111-111111111111'
        $r.ResolvedDisplay | Should -Be 'Contoso'
        $r.DerivedRoles | Should -Contain 'Application Mail.Read'

        $r.Errors | Should -BeNullOrEmpty
        Test-Path $r.ConfigPath | Should -BeTrue
        $config = InModuleScope EXORBACforAppManagement -Parameters @{ Path = $r.ConfigPath } {
            param($Path)
            ConvertFrom-RBAC4AppYaml -Content (Get-Content $Path -Raw)
        }
        $config.SchemaVersion | Should -Be '4.3'
        # The file carries the full conversion result.
        $config.ConversionResult.AppId | Should -Be $r.AppId
        $config.ConversionResult.ResolvedDisplay | Should -Be 'Contoso'
        $config.ConversionResult.AccessRight | Should -Be $r.AccessRight
        $config.ConversionResult.ScopeGroup | Should -Be 'EvenUsers'
        @($config.ConversionResult.DerivedRoles) | Should -Be @($r.DerivedRoles)
        @($config.ConversionResult.SkippedPermissions) | Should -Be @($r.SkippedPermissions)
        $config.ConversionResult.ConfigPath | Should -Be $r.ConfigPath
        @($config.Runtime.CollectedWarnings) | Should -Be @($r.Warnings)
        $config.Runtime.GeneratedAt | Should -Not -BeNullOrEmpty
        $config.Application.SpObjectId | Should -Be '22222222-2222-2222-2222-222222222222'
        $config.Rbac.Roles | Should -Contain 'Application Mail.Read'
        $config.RbacScope.AccessGroupName | Should -Be 'EvenUsers'
        $config.RbacScope.ScopeKind | Should -Be 'Group'
        $config.RbacScope.AssignmentScope | Should -Be 'RecipientGroupScope'
        $config.Application.TenantId | Should -Be 'tenant-id-123'
        Split-Path $r.ConfigPath -Leaf | Should -Match '^rbac4app-Contoso-EvenUsers-11111111-1111-1111-1111-111111111111-\d{14}-[a-f0-9]{32}\.yml$'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppEntry -Times 0
    }

    It 'keeps the policy ScopeName group as a reference-only MailEnabledSecurityGroup' {
        $r = Convert-ApplicationAccessPolicyToRBAC -Format Json -OutputPath $TestDrive -Confirm:$false
        $config = Get-Content $r.ConfigPath -Raw | ConvertFrom-Json
        $config.RbacScope.AccessGroupType | Should -Be 'MailEnabledSecurityGroup'
        $config.RbacScope.AccessGroupName | Should -BeExactly 'EvenUsers'
        foreach ($key in 'GroupPrefix', 'ManagedBy', 'Members', 'BootstrapMember', 'SeparateScopePerRole') {
            $config.RbacScope.PSObject.Properties.Name | Should -Not -Contain $key
        }
        $config.Application.AppId | Should -Be $r.AppId
        $config.Application.DisplayName | Should -Be 'Contoso'
        # Absent AssignmentScope means RecipientGroupScope for a Group-kind schema 4.3 config.
        $config.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'AssignmentScope'
        $r.ConfigPath | Should -Match '\.json$'
    }

    It 'records a ScopeName with spaces and special characters verbatim (no sanitizing or shortening)' {
        $scopeName = "Mail App Scope (Prod) - Sales & Marketing 'EU' " + ('x' * 60)
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy {
            [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; AccessRight = 'RestrictAccess'; ScopeName = $scopeName }
        }

        foreach ($format in 'Yaml', 'Json') {
            $r = Convert-ApplicationAccessPolicyToRBAC -Format $format -OutputPath $TestDrive -Confirm:$false
            $r.Errors | Should -BeNullOrEmpty
            $r.ScopeGroup | Should -BeExactly $scopeName
            $config = InModuleScope EXORBACforAppManagement -Parameters @{ Path = $r.ConfigPath; Format = $format } {
                param($Path, $Format)
                $content = Get-Content $Path -Raw
                if ($Format -eq 'Json') { Complete-RBAC4AppConfig -Config ($content | ConvertFrom-Json) } else { ConvertFrom-RBAC4AppYaml -Content $content }
            }
            $config.RbacScope.AccessGroupName | Should -BeExactly $scopeName
            $config.RbacScope.AccessGroupType | Should -Be 'MailEnabledSecurityGroup'
        }
    }

    It 'reports a policy without a ScopeName as an error instead of inventing a group' {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy {
            [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; AccessRight = 'RestrictAccess'; ScopeName = '' }
        }

        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false

        $r.Errors | Should -Match 'no ScopeName'
        $r.ConfigPath | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 0
    }

    It 'ignores the deprecated -AccessGroupType, -GroupPrefix, and -ManagedBy with a warning each' {
        $warnings = @()
        $r = Convert-ApplicationAccessPolicyToRBAC -AccessGroupType M365Group -GroupPrefix Custom -ManagedBy 'owner@contoso.com' `
            -Format Json -OutputPath $TestDrive -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue

        @($warnings | Where-Object { "$_" -like '*deprecated and ignored*' }).Count | Should -Be 3
        $config = Get-Content $r.ConfigPath -Raw | ConvertFrom-Json
        $config.RbacScope.AccessGroupType | Should -Be 'MailEnabledSecurityGroup'
        $config.RbacScope.AccessGroupName | Should -Be 'EvenUsers'
        $config.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'GroupPrefix'
        $config.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'ManagedBy'
    }

    It 'maps the legacy EWS scope full_access_as_app to Application EWS.AccessAsApp' {
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false
        $r.DerivedRoles | Should -Contain 'Application EWS.AccessAsApp'
    }

    It 'records grants with no Application Access Policy equivalent as skipped' {
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false
        $r.SkippedPermissions | Should -Contain 'Directory.Read.All'
        $r.DerivedRoles | Should -Not -Contain 'Application Directory.Read.All'
    }

    It 'skips DenyAccess policies with a warning and does not assign roles' {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy {
            [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; AccessRight = 'DenyAccess'; ScopeName = 'EvenUsers' }
        }

        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -WarningAction SilentlyContinue

        $r.Warnings | Should -Not -BeNullOrEmpty
        $r.ConfigPath | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppEntry -Times 0
    }

    It 'uses an explicit -Role override instead of deriving from grants' {
        $r = Convert-ApplicationAccessPolicyToRBAC -Role 'Mail.Send' -Format Json -OutputPath $TestDrive -Confirm:$false

        $r.DerivedRoles | Should -Be @('Application Mail.Send')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipalAppRoleAssignment -Times 0
        (Get-Content $r.ConfigPath -Raw | ConvertFrom-Json).Rbac.Roles | Should -Be @('Application Mail.Send')
    }

    It 'does not write files when -WhatIf is supplied' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'whatif')
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $dir.FullName -WhatIf
        $r.ConfigPath | Should -BeNullOrEmpty
        @(Get-ChildItem $dir.FullName).Count | Should -Be 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppEntry -Times 0
    }

    It 'writes distinct safe filenames for piped policies and repeated conversions' {
        $policies = @(
            [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; AccessRight = 'RestrictAccess'; ScopeName = '../Even Users' }
            [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; AccessRight = 'RestrictAccess'; ScopeName = 'OddUsers' }
        )
        $results = @($policies | Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false)
        $repeated = $policies[0] | Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false
        @(@($results.ConfigPath) + $repeated.ConfigPath | Select-Object -Unique).Count | Should -Be 3
        foreach ($r in @($results) + $repeated) {
            $r.Errors | Should -BeNullOrEmpty
            Test-Path $r.ConfigPath | Should -BeTrue
            Split-Path $r.ConfigPath -Parent | Should -Be $TestDrive
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ApplicationAccessPolicy -Times 0
    }

    It 'records file write errors without returning a config path' {
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath (Join-Path $TestDrive 'missing') -Confirm:$false
        $r.Errors | Should -Not -BeNullOrEmpty
        $r.ConfigPath | Should -BeNullOrEmpty
    }

    It 'resolves relative output directories against the PowerShell location' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'relative')
        Push-Location $TestDrive
        try {
            $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath './relative' -Confirm:$false
            $r.Errors | Should -BeNullOrEmpty
            Split-Path $r.ConfigPath -Parent | Should -Be $dir.FullName
            Test-Path $r.ConfigPath | Should -BeTrue
        }
        finally {
            Pop-Location
        }
    }

    It 'skips policies without convertible roles' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment { @() }
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false -WarningAction SilentlyContinue
        $r.Warnings | Should -Not -BeNullOrEmpty
        $r.ConfigPath | Should -BeNullOrEmpty
    }

    It 'end to end: Invoke-RBAC4AppConfig binds the roles to the existing ScopeName group and never changes it' {
        $scopeName = 'Mail App Scope (Prod) & Co'
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy {
            [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; AccessRight = 'RestrictAccess'; ScopeName = $scopeName }
        }
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false
        $r.Errors | Should -BeNullOrEmpty

        # Exchange Online cmdlets Invoke-RBAC4AppConfig may call - read-only ones answer, mutating
        # group cmdlets must never be reached for the kept group.
        $exo = @{
            'Get-ConnectionInformation' = 'param()'
            'Get-ServicePrincipal' = 'param($Identity)'
            'New-ServicePrincipal' = 'param($AppId, $ObjectId, $DisplayName)'
            'Get-Recipient' = 'param($Identity, $RecipientPreviewFilter, $ResultSize, $Anr)'
            'Get-ManagementRoleAssignment' = 'param($Role, $Identity, $RoleAssignee)'
            'New-ManagementRoleAssignment' = 'param($App, $Role, $CustomResourceScope, $RecipientGroupScope, $Name)'
            'Get-DistributionGroup' = 'param($Identity)'; 'New-DistributionGroup' = 'param($Name)'; 'Set-DistributionGroup' = 'param($Identity)'
            'Get-DistributionGroupMember' = 'param($Identity)'; 'Add-DistributionGroupMember' = 'param($Identity, $Member)'
            'Get-UnifiedGroup' = 'param($Identity)'; 'New-UnifiedGroup' = 'param($Name)'; 'Set-UnifiedGroup' = 'param($Identity)'
            'Get-UnifiedGroupLinks' = 'param($Identity, $LinkType)'; 'Add-UnifiedGroupLinks' = 'param($Identity, $LinkType, $Links)'
        }
        foreach ($name in $exo.Keys) { Set-Item -Path "Function:\global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($exo[$name])")) }
        try {
            Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
                [pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222'; Identity = '22222222-2222-2222-2222-222222222222' }
            }
            Mock -ModuleName EXORBACforAppManagement Get-Recipient {
                if ($Identity -eq $scopeName) {
                    [pscustomobject]@{ Name = $scopeName; DisplayName = $scopeName; RecipientTypeDetails = 'MailUniversalSecurityGroup'; ManagedBy = @('admin') }
                }
            }
            Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
            Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { [pscustomobject]@{ Name = $Name } }
            foreach ($mutating in 'New-DistributionGroup', 'Set-DistributionGroup', 'Add-DistributionGroupMember',
                                  'New-UnifiedGroup', 'Set-UnifiedGroup', 'Add-UnifiedGroupLinks') {
                Mock -ModuleName EXORBACforAppManagement $mutating { throw "$($MyInvocation.MyCommand.Name) must not be called for the kept group" }
            }

            $result = Invoke-RBAC4AppConfig -Path $r.ConfigPath -Confirm:$false -WarningAction SilentlyContinue

            $result.Errors | Should -BeNullOrEmpty
            $result.ScopeGroupName | Should -BeExactly $scopeName
            Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 2 -Exactly -ParameterFilter {
                $RecipientGroupScope -ceq $scopeName -and -not $CustomResourceScope
            }
            foreach ($mutating in 'New-DistributionGroup', 'Set-DistributionGroup', 'Add-DistributionGroupMember',
                                  'New-UnifiedGroup', 'Set-UnifiedGroup', 'Add-UnifiedGroupLinks') {
                Should -Invoke -ModuleName EXORBACforAppManagement -CommandName $mutating -Times 0
            }
        }
        finally {
            foreach ($name in $exo.Keys) { Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue }
        }
    }

    It 'filters policies by AppId and still keeps the policy ScopeName group' {
        $r = Convert-ApplicationAccessPolicyToRBAC -AppId '11111111-1111-1111-1111-111111111111' `
            -Format Json -OutputPath $TestDrive -Confirm:$false
        $config = Get-Content $r.ConfigPath -Raw | ConvertFrom-Json
        $completed = InModuleScope EXORBACforAppManagement -Parameters @{ Config = $config } { param($Config) Complete-RBAC4AppConfig -Config $Config }
        $completed.RbacScope.AccessGroupName | Should -Be 'EvenUsers'
        $completed.RbacScope.AccessGroupType | Should -Be 'MailEnabledSecurityGroup'
        Should -Invoke -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy -Times 1 -ParameterFilter {
            $AppId -eq '11111111-1111-1111-1111-111111111111'
        }
    }
}

Describe 'Get-LegacyScopeRoleMap' {
    It 'maps every legacy scope to a valid Get-AppRoleMap role' {
        InModuleScope EXORBACforAppManagement {
            $appRoles = Get-AppRoleMap
            $legacy   = Get-LegacyScopeRoleMap
            foreach ($value in $legacy.Values) {
                $appRoles.Contains($value) | Should -BeTrue -Because "$value should be a key in Get-AppRoleMap"
            }
        }
    }
}

Describe 'Convert-ApplicationAccessPolicyToRBAC failure paths' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy {
            [pscustomobject]@{
                AppId       = '11111111-1111-1111-1111-111111111111'
                AccessRight = 'RestrictAccess'
                ScopeName   = 'EvenUsers'
                Description = 'Restrict app to EvenUsers'
            }
        }

        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            # Pester only defines the parameter variable when it was bound on the call,
            # so Test-Path is the StrictMode-safe way to tell the two call shapes apart.
            if (Test-Path variable:ServicePrincipalId) {
                # Resource service principal (e.g. Microsoft Graph) AppRoles catalog.
                return [pscustomobject]@{
                    Id       = $ServicePrincipalId
                    AppRoles = @(
                        [pscustomobject]@{ Id = 'role-mailread'; Value = 'Mail.Read' }
                        [pscustomobject]@{ Id = 'role-ews';      Value = 'full_access_as_app' }
                        [pscustomobject]@{ Id = 'role-dir';      Value = 'Directory.Read.All' }
                    )
                }
            }
            # App service principal resolution by appId filter.
            [pscustomobject]@{
                DisplayName = 'Contoso'
                AppId       = '11111111-1111-1111-1111-111111111111'
                Id          = '22222222-2222-2222-2222-222222222222'
            }
        }

        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment {
            @(
                [pscustomobject]@{ AppRoleId = 'role-mailread'; ResourceId = '99999999-9999-9999-9999-999999999999' }
                [pscustomobject]@{ AppRoleId = 'role-ews';      ResourceId = '99999999-9999-9999-9999-999999999999' }
                [pscustomobject]@{ AppRoleId = 'role-dir';      ResourceId = '99999999-9999-9999-9999-999999999999' }
            )
        }

        Mock -ModuleName EXORBACforAppManagement New-RBAC4AppEntry {
            [pscustomobject]@{ Warnings = @(); Errors = @() }
        }
        Mock -ModuleName EXORBACforAppManagement Get-MgContext {
            [pscustomobject]@{ TenantId = 'tenant-id-123' }
        }
    }

    It 'writes an error when reading the Application Access Policies fails' {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy { throw 'access denied' }
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($err -join ';') | Should -Match 'Failed to read Application Access Policies: access denied'
    }

    It 'returns nothing when there are no policies to convert' {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy { }
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false
        $r | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 0
    }

    It 'writes the config without a TenantId when Get-MgContext fails' {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { throw 'not connected' }
        $r = Convert-ApplicationAccessPolicyToRBAC -Format Json -OutputPath $TestDrive -Confirm:$false
        $r.Errors | Should -BeNullOrEmpty
        (Get-Content $r.ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'TenantId'
        (Get-Content $r.ConfigPath -Raw | ConvertFrom-Json).Application.PSObject.Properties.Name | Should -Not -Contain 'TenantId'
    }

    It 'records a grant whose permission name cannot be resolved as skipped' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment {
            @(
                [pscustomobject]@{ AppRoleId = 'role-mailread'; ResourceId = '99999999-9999-9999-9999-999999999999' }
                [pscustomobject]@{ AppRoleId = 'role-unknown';  ResourceId = '99999999-9999-9999-9999-999999999999' }
            )
        }
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false
        $r.SkippedPermissions | Should -Contain 'AppRoleId role-unknown (could not resolve permission name)'
        $r.ConfigPath | Should -Not -BeNullOrEmpty
    }
}
