#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Both functions are private: call them through module-scoped command references so
    # Mock -ModuleName, pipeline input, and common parameters (-WhatIf, -ErrorVariable) behave as
    # they would for a public function.
    $script:ResolveApplicationAccessPolicy = & (Get-Module EXORBACforAppManagement) { Get-Command -Name Resolve-ApplicationAccessPolicy -CommandType Function }
    $script:InvokeMsGraphEntraIDApiPerm = & (Get-Module EXORBACforAppManagement) { Get-Command -Name Invoke-MsGraphEntraIDApiPerm -CommandType Function }

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
        $result = & $script:ResolveApplicationAccessPolicy -OutputPath $TestDrive -Confirm:$false

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
        $result = & $script:ResolveApplicationAccessPolicy -AppId '11111111-1111-1111-1111-111111111111' `
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
        $result = & $script:ResolveApplicationAccessPolicy -OutputPath $whatIfPath.FullName -WhatIf
        $result.ConfigPath | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $whatIfPath.FullName).Count | Should -Be 0
    }
}

Describe 'Resolve-ApplicationAccessPolicy input and failure paths' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy { $script:Policies }
    }

    It 'uses piped policies instead of reading them from Exchange Online' {
        $result = $script:Policies | & $script:ResolveApplicationAccessPolicy -OutputPath $TestDrive -Confirm:$false
        $result.Policies.Count | Should -Be 1
        $result.Policies[0].AppId | Should -Be '11111111-1111-1111-1111-111111111111'
        Should -Invoke -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy -Times 0
    }

    It 'writes an error and no file when reading the policies fails' {
        Mock -ModuleName EXORBACforAppManagement Get-ApplicationAccessPolicy { throw 'access denied' }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'read-fails') -Force
        $result = & $script:ResolveApplicationAccessPolicy -OutputPath $dir.FullName -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty
        ($err -join ';') | Should -Match 'Failed to read Application Access Policies: access denied'
        @(Get-ChildItem -LiteralPath $dir.FullName).Count | Should -Be 0
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
        $source = & $script:ResolveApplicationAccessPolicy -OutputPath $TestDrive -Confirm:$false
        $result = $source | & $script:InvokeMsGraphEntraIDApiPerm -Confirm:$false

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
        $source = & $script:ResolveApplicationAccessPolicy -Format Json -OutputPath $TestDrive -Confirm:$false
        $result = & $script:InvokeMsGraphEntraIDApiPerm -Path $source.ConfigPath -Confirm:$false

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

        $result = & $script:InvokeMsGraphEntraIDApiPerm -Path $path -Confirm:$false

        $result.Errors | Should -Contain "Invalid AppId '11111111' or appId ne '' in the policy export."
        $result.Policies[0].Permissions | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement Get-MgServicePrincipal -Times 1
    }
}
