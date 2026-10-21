#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-MgServicePrincipal { param([string]$Filter, [string]$ServicePrincipalId) }
    function global:Get-MgContext { }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-MgServicePrincipal', 'Get-MgContext') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppConfig' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext {
            [pscustomobject]@{ TenantId = 'tenant-id-123'; Account = 'admin@contoso.com' }
        }
    }

    It 'resolves SP by display name and writes YAML with correct Application fields' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-obj-id'; AppId = 'app-client-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -Role 'Mail.Send' -Members 'shared@contoso.com' -OutputPath $TestDrive -Confirm:$false

        $outFile         | Should -Not -BeNullOrEmpty
        (Test-Path $outFile) | Should -BeTrue
        $content = Get-Content $outFile -Raw
        $content | Should -Match 'AppId:.*app-client-id'
        $content | Should -Match 'SpObjectId:.*sp-obj-id'
        $content | Should -Match 'DisplayName:.*Contoso'
        $content | Should -Match 'TenantId:.*tenant-id-123'
    }

    It 'escapes single quotes in display-name OData filters' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-obj-id'; AppId = 'app-client-id'; DisplayName = "O'Brien App" }
        } -ParameterFilter { $Filter -eq "displayName eq 'O''Brien App'" }

        $outFile = New-RBAC4AppConfig -RegisteredAppName "O'Brien App" -OutputPath $TestDrive -Confirm:$false

        (Test-Path $outFile) | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 1 -ParameterFilter {
            $Filter -eq "displayName eq 'O''Brien App'"
        }
    }

    It 'normalises short role names to Application form in the YAML' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -Role 'Mail.Send' -OutputPath $TestDrive -Confirm:$false

        (Get-Content $outFile -Raw) | Should -Match 'Application Mail\.Send'
    }

    It 'writes ChangeReference into the YAML config' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }

        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -Role 'Mail.Send' -ChangeReference 'CHG123456' -OutputPath $TestDrive -Confirm:$false

        (Get-Content $outFile -Raw) | Should -Match 'ChangeReference: "CHG123456"'
    }

    It 'resolves SP by AppId' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = '11111111-1111-1111-1111-111111111111'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -AppId '11111111-1111-1111-1111-111111111111' `
            -OutputPath $TestDrive -Confirm:$false
        (Test-Path $outFile) | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 1
    }

    It 'resolves SP by SpObjectId' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -SpObjectId '22222222-2222-2222-2222-222222222222' `
            -OutputPath $TestDrive -Confirm:$false
        (Test-Path $outFile) | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 1
    }

    It 'writes nothing and returns nothing under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $emptyDir = Join-Path $TestDrive 'whatif-check'
        $null = New-Item -ItemType Directory -Path $emptyDir -Force
        $result = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $emptyDir -WhatIf
        $result | Should -BeNullOrEmpty
        @(Get-ChildItem $emptyDir -Filter '*.yml').Count | Should -Be 0
    }

    It 'records an error when the SP is not found by name' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { @() }
        $err = $null
        $null = New-RBAC4AppConfig -RegisteredAppName 'Unknown App' `
            -OutputPath $TestDrive -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue
        $err | Should -Not -BeNullOrEmpty
    }

    It 'includes AccessGroupType and Members in the YAML' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -AccessGroupType DistributionList -Members 'box@contoso.com' `
            -OutputPath $TestDrive -Confirm:$false

        $content = Get-Content $outFile -Raw
        $content | Should -Match 'AccessGroupType: "DistributionList"'
        $content | Should -Match 'box@contoso\.com'
    }

    It 'generates a concrete scope group name in the config when one is not explicitly provided' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }

        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -AccessGroupType DistributionList -OutputPath $TestDrive -Confirm:$false

        $content = Get-Content $outFile -Raw
        $content | Should -Match 'AccessGroupName: "UDLRAo1P-Contoso"'
    }

    It 'writes a .yml file by default' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $TestDrive -Confirm:$false
        $outFile | Should -BeLike '*.yml'
    }

    It '-Format Json writes a .json file with the same schema as the YAML output' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-obj-id'; AppId = 'app-client-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Role 'Mail.Send' `
            -Members 'shared@contoso.com' -ManagedBy 'owner1@contoso.com', 'owner2@contoso.com' `
            -Format Json -OutputPath $TestDrive -Confirm:$false

        $outFile | Should -BeLike '*.json'
        (Test-Path $outFile) | Should -BeTrue

        $parsed = Get-Content $outFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion              | Should -Be '4.0'
        $parsed.RbacScope.ScopeKind        | Should -Be 'Group'
        $parsed.RbacScope.ManagementScopePrefix | Should -Be 'MSRAo1P'
        $parsed.TenantId                   | Should -Be 'tenant-id-123'
        $parsed.Application.AppId          | Should -Be 'app-client-id'
        $parsed.Application.SpObjectId     | Should -Be 'sp-obj-id'
        $parsed.Application.DisplayName    | Should -Be 'Contoso'
        $parsed.Rbac.Roles                 | Should -Contain 'Application Mail.Send'
        $parsed.Rbac.ChangeReference       | Should -Be ''
        $parsed.RbacScope.Members          | Should -Contain 'shared@contoso.com'
        $parsed.RbacScope.ManagedBy        | Should -Contain 'owner1@contoso.com'
        $parsed.RbacScope.ManagedBy        | Should -Contain 'owner2@contoso.com'
    }

    It 'writes SeparateScopePerRole to YAML and JSON configs' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }

        $yamlPath = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Role 'Mail.Send', 'Calendars.Read' `
            -SeparateScopePerRole -OutputPath $TestDrive -Confirm:$false
        $yaml = Get-Content $yamlPath -Raw
        $yaml | Should -Match 'SeparateScopePerRole: "True"'
        $parsedYaml = InModuleScope EXORBACforAppManagement -Parameters @{ Content = $yaml } {
            param($Content)
            ConvertFrom-RBAC4AppYaml -Content $Content
        }
        $parsedYaml.RbacScope.SeparateScopePerRole | Should -BeTrue

        $jsonPath = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -SeparateScopePerPermission `
            -Format Json -OutputPath $TestDrive -Confirm:$false
        $parsedJson = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $parsedJson.RbacScope.SeparateScopePerRole | Should -BeTrue
    }

    It 'requires Group scope when SeparateScopePerRole is enabled' {
        { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Tag -SeparateScopePerRole -OutputPath $TestDrive } |
            Should -Throw '*can only be used with -ScopeKind Group*'
    }

    It 'writes the management scope settings for -ScopeKind Recipients and round-trips them' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Recipients `
            -ScopeRecipients 'alice@contoso.com', 'bob@contoso.com' -ManagementScopeName 'Contoso-Scope' `
            -OutputPath $TestDrive -Confirm:$false

        $content = Get-Content $outFile -Raw
        $content | Should -Match 'SchemaVersion: "4.0"'
        $content | Should -Match 'ScopeKind: "Recipients"'
        $parsed = InModuleScope EXORBACforAppManagement -Parameters @{ Content = $content } { param($Content) ConvertFrom-RBAC4AppYaml -Content $Content }
        $parsed.RbacScope.ScopeKind           | Should -Be 'Recipients'
        $parsed.RbacScope.ManagementScopeName | Should -Be 'Contoso-Scope'
        @($parsed.RbacScope.ScopeRecipients)  | Should -Be @('alice@contoso.com', 'bob@contoso.com')
    }

    It 'requires -ScopeRecipients for -ScopeKind Recipients' {
        { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Recipients -OutputPath $TestDrive -Confirm:$false } |
            Should -Throw '*-ScopeRecipients is required*'
    }

    It 'rejects -ManagementScopeName together with -ManagementScopePrefix' {
        { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ManagementScopeName 'a' -ManagementScopePrefix 'b' -OutputPath $TestDrive -Confirm:$false } |
            Should -Throw '*cannot be used together*'
    }

    It 'warns when a group-only parameter is supplied for a non-Group scope kind' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $null = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Tag -Members 'x@contoso.com' `
            -OutputPath $TestDrive -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ';') | Should -Match '-Members only applies to -ScopeKind Group'
    }

    It '-Format Json writes nothing under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $emptyDir = Join-Path $TestDrive 'whatif-check-json'
        $null = New-Item -ItemType Directory -Path $emptyDir -Force
        $result = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Format Json -OutputPath $emptyDir -WhatIf
        $result | Should -BeNullOrEmpty
        @(Get-ChildItem $emptyDir -Filter '*.json').Count | Should -Be 0
    }
}
