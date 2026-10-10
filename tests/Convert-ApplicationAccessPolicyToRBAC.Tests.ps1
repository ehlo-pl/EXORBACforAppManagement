#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs for the external cmdlets the function calls, declaring the parameters
    # it filters on so Mock -ModuleName can bind and intercept them.
    function global:Get-ApplicationAccessPolicy { [CmdletBinding()] param([string]$AppId) }
    function global:Get-MgServicePrincipal { [CmdletBinding()] param([string]$Filter, [string]$ServicePrincipalId) }
    function global:Get-MgServicePrincipalAppRoleAssignment { [CmdletBinding()] param([string]$ServicePrincipalId) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }
    function global:Get-MgContext { [CmdletBinding()] param() }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ApplicationAccessPolicy','Get-MgServicePrincipal','Get-MgServicePrincipalAppRoleAssignment','Get-DistributionGroupMember','Get-MgContext') {
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

        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @(
                [pscustomobject]@{ PrimarySmtpAddress = 'user1@contoso.com' }
                [pscustomobject]@{ PrimarySmtpAddress = 'user2@contoso.com' }
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
        $r.MembersCopied | Should -Be @('user1@contoso.com', 'user2@contoso.com')

        $r.Errors | Should -BeNullOrEmpty
        Test-Path $r.ConfigPath | Should -BeTrue
        $config = InModuleScope EXORBACforAppManagement -Parameters @{ Path = $r.ConfigPath } {
            param($Path)
            ConvertFrom-RBAC4AppYaml -Content (Get-Content $Path -Raw)
        }
        $config.SchemaVersion | Should -Be '4.0'
        $config.Application.SpObjectId | Should -Be '22222222-2222-2222-2222-222222222222'
        $config.Rbac.Roles | Should -Contain 'Application Mail.Read'
        $config.RbacScope.Members | Should -Be @('user1@contoso.com', 'user2@contoso.com')
        $config.RbacScope.ScopeKind | Should -Be 'Group'
        $config.RbacScope.GroupPrefix | Should -Be 'UDLRAo1P'
        $config.TenantId | Should -Be 'tenant-id-123'
        Split-Path $r.ConfigPath -Leaf | Should -Match '^rbac4app-Contoso-EvenUsers-11111111-1111-1111-1111-111111111111-\d{14}-[a-f0-9]{32}\.yml$'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-RBAC4AppEntry -Times 0
    }

    It 'records group type, prefix, and owners in JSON' {
        $r = Convert-ApplicationAccessPolicyToRBAC -AccessGroupType M365Group -GroupPrefix Custom `
            -ManagedBy 'owner@contoso.com' -Format Json -OutputPath $TestDrive -Confirm:$false
        $config = Get-Content $r.ConfigPath -Raw | ConvertFrom-Json
        $config.RbacScope.AccessGroupType | Should -Be 'M365Group'
        $config.RbacScope.GroupPrefix | Should -Be 'Custom'
        $config.RbacScope.ManagedBy | Should -Be @('owner@contoso.com')
        $config.Application.AppId | Should -Be $r.AppId
        $config.Application.DisplayName | Should -Be 'Contoso'
        $config.RbacScope.ManagementScopePrefix | Should -Be 'MSRAo1P'
        $r.ConfigPath | Should -Match '\.json$'
    }

    It 'rejects MailEnabledSecurityGroup (not a valid conversion target)' {
        { Convert-ApplicationAccessPolicyToRBAC -AccessGroupType MailEnabledSecurityGroup -Confirm:$false } |
            Should -Throw '*MailEnabledSecurityGroup*'
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

    It 'does not generate an incomplete config when source membership cannot be read' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { throw 'Access denied' }
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false -WarningAction SilentlyContinue
        $r.Errors | Should -Not -BeNullOrEmpty
        $r.ConfigPath | Should -BeNullOrEmpty
    }

    It 'records file write errors without returning a config path' {
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath (Join-Path $TestDrive 'missing') -Confirm:$false
        $r.Errors | Should -Not -BeNullOrEmpty
        $r.ConfigPath | Should -BeNullOrEmpty
    }

    It 'skips policies without convertible roles' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment { @() }
        $r = Convert-ApplicationAccessPolicyToRBAC -OutputPath $TestDrive -Confirm:$false -WarningAction SilentlyContinue
        $r.Warnings | Should -Not -BeNullOrEmpty
        $r.ConfigPath | Should -BeNullOrEmpty
    }

    It 'filters policies by AppId and keeps the M365Group default prefix' {
        $r = Convert-ApplicationAccessPolicyToRBAC -AppId '11111111-1111-1111-1111-111111111111' `
            -AccessGroupType M365Group -Format Json -OutputPath $TestDrive -Confirm:$false
        (Get-Content $r.ConfigPath -Raw | ConvertFrom-Json).RbacScope.GroupPrefix | Should -Be 'Um365RAo1P'
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
