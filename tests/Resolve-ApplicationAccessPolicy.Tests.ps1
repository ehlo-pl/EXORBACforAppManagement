#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-ApplicationAccessPolicy { [CmdletBinding()] param([string]$AppId) }
    function global:Get-MgServicePrincipal { [CmdletBinding()] param([string]$Filter) }
    function global:Get-MgServicePrincipalAppRoleAssignment { [CmdletBinding()] param([string]$ServicePrincipalId) }

    $script:Policies = @(
        [pscustomobject]@{
            ScopeName = 'Even Users'
            ScopeIdentity = 'EvenUsers@contoso.com'
            AppId = '11111111-1111-1111-1111-111111111111'
            AccessRight = 'RestrictAccess'
        }
    )
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($name in 'Get-ApplicationAccessPolicy', 'Get-MgServicePrincipal', 'Get-MgServicePrincipalAppRoleAssignment') {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-ApplicationAccessPolicy' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy { $script:Policies }
    }

    It 'writes all requested fields to YAML and leaves Permissions empty' {
        $result = Resolve-ApplicationAccessPolicy -OutputPath $TestDrive -Confirm:$false

        $result.Errors | Should -BeNullOrEmpty
        Test-Path $result.ConfigPath | Should -BeTrue
        $result.ConfigPath | Should -Match '\.yml$'
        $result.Policies[0].PSObject.Properties.Name | Should -Be @('ScopeName', 'ScopeIdentity', 'AppId', 'AccessRight', 'Group', 'Permissions')
        $result.Policies[0].ScopeName | Should -Be 'Even Users'
        $result.Policies[0].ScopeIdentity | Should -Be 'EvenUsers@contoso.com'
        $result.Policies[0].Group | Should -Be 'Even Users'
        $result.Policies[0].Permissions | Should -BeNullOrEmpty

        $read = InModuleScope EXORBACforAppManagement -Parameters @{ Path = $result.ConfigPath } {
            param($Path)
            ConvertFrom-ApplicationAccessPolicyYaml -Content (Get-Content -LiteralPath $Path -Raw)
        }
        $read.Policies[0].AppId | Should -Be '11111111-1111-1111-1111-111111111111'
        $read.Policies[0].Permissions | Should -BeNullOrEmpty
    }

    It 'writes JSON and filters by AppId' {
        $result = Resolve-ApplicationAccessPolicy -AppId '11111111-1111-1111-1111-111111111111' `
            -Format Json -OutputPath $TestDrive -Confirm:$false

        $result.ConfigPath | Should -Match '\.json$'
        $json = Get-Content -LiteralPath $result.ConfigPath -Raw | ConvertFrom-Json
        $json.Policies[0].AccessRight | Should -Be 'RestrictAccess'
        $json.Policies[0].Permissions | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy -Times 1 -ParameterFilter {
            $AppId -eq '11111111-1111-1111-1111-111111111111'
        }
    }

    It 'does not create a file with WhatIf' {
        $whatIfPath = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'whatif')
        $result = Resolve-ApplicationAccessPolicy -OutputPath $whatIfPath.FullName -WhatIf
        $result.ConfigPath | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $whatIfPath.FullName).Count | Should -Be 0
    }
}

Describe 'Invoke-MsGraphEntraIDApiPerm' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy { $script:Policies }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            if ($Filter -like "*00000003-0000-0000-c000-000000000000*") {
                return [pscustomobject]@{
                    Id = 'graph-resource'
                    AppRoles = @(
                        [pscustomobject]@{ Id = 'mail-read'; Value = 'Mail.Read' }
                        [pscustomobject]@{ Id = 'calendar-read'; Value = 'Calendars.Read' }
                        [pscustomobject]@{ Id = 'contacts-read'; Value = 'Contacts.Read' }
                        [pscustomobject]@{ Id = 'user-read'; Value = 'User.Read' }
                    )
                }
            }
            [pscustomobject]@{
                Id = 'app-service-principal'
                AppId = '11111111-1111-1111-1111-111111111111'
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment {
            @(
                [pscustomobject]@{ AppRoleId = 'mail-read'; ResourceId = 'graph-resource' }
                [pscustomobject]@{ AppRoleId = 'calendar-read'; ResourceId = 'graph-resource' }
                [pscustomobject]@{ AppRoleId = 'contacts-read'; ResourceId = 'graph-resource' }
                [pscustomobject]@{ AppRoleId = 'user-read'; ResourceId = 'graph-resource' }
                [pscustomobject]@{ AppRoleId = 'mail-read'; ResourceId = 'another-resource' }
            )
        }
    }

    It 'adds only Microsoft Graph mail, calendar, and contacts application permissions to a copied YAML file' {
        $source = Resolve-ApplicationAccessPolicy -OutputPath $TestDrive -Confirm:$false
        $result = $source | Invoke-MsGraphEntraIDApiPerm -Confirm:$false

        $result.InputPath | Should -Be $source.ConfigPath
        $result.OutputPath | Should -Not -Be $source.ConfigPath
        Test-Path $result.OutputPath | Should -BeTrue
        $result.Policies[0].Permissions | Should -Be @('Calendars.Read', 'Contacts.Read', 'Mail.Read')
        $source.Policies[0].Permissions | Should -BeNullOrEmpty

        $read = InModuleScope EXORBACforAppManagement -Parameters @{ Path = $result.OutputPath } {
            param($Path)
            ConvertFrom-ApplicationAccessPolicyYaml -Content (Get-Content -LiteralPath $Path -Raw)
        }
        $read.Policies[0].Permissions | Should -Be @('Calendars.Read', 'Contacts.Read', 'Mail.Read')
    }

    It 'reads and enriches a JSON file' {
        $source = Resolve-ApplicationAccessPolicy -Format Json -OutputPath $TestDrive -Confirm:$false
        $result = Invoke-MsGraphEntraIDApiPerm -Path $source.ConfigPath -Confirm:$false

        $result.OutputPath | Should -Match '\.json$'
        $read = Get-Content -LiteralPath $result.OutputPath -Raw | ConvertFrom-Json
        $read.Policies[0].Permissions | Should -Be @('Calendars.Read', 'Contacts.Read', 'Mail.Read')
    }

    It 'rejects malformed AppIds before using them in a Graph filter' {
        $path = Join-Path $TestDrive 'invalid-app-id.json'
        [pscustomobject]@{
            Policies = @([pscustomobject]@{
                ScopeName = 'Scope'
                ScopeIdentity = 'scope@contoso.com'
                AppId = "11111111' or appId ne '"
                AccessRight = 'RestrictAccess'
                Group = 'Scope'
                Permissions = @()
            })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path

        $result = Invoke-MsGraphEntraIDApiPerm -Path $path -Confirm:$false

        $result.Errors | Should -Contain "Invalid AppId '11111111' or appId ne '' in the policy export."
        $result.Policies[0].Permissions | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement Get-MgServicePrincipal -Times 1
    }
}
