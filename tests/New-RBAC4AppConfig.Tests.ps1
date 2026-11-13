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
        $content | Should -Match '(?m)^  TenantId: \"tenant-id-123\"'
        $content | Should -Not -Match '(?m)^TenantId:'
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

    It 'writes ChangeReference under Metadata in the YAML config' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }

        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' `
            -Role 'Mail.Send' -ChangeReference 'CHG123456' -OutputPath $TestDrive -Confirm:$false

        $content = Get-Content $outFile -Raw
        $content | Should -Match '(?ms)^Metadata:\r?\n.*?^  ChangeReference: "CHG123456"'
        $content | Should -Not -Match '(?m)^Rbac:\r?\n  ChangeReference:'
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
        # DistributionList is no longer the default (CloudMailEnabledSecurityGroup is), so it is written.
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
            -ChangeReference 'CHG-JSON' `
            -Format Json -OutputPath $TestDrive -Confirm:$false

        $outFile | Should -BeLike '*.json'
        (Test-Path $outFile) | Should -BeTrue

        $parsed = Get-Content $outFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion              | Should -Be '4.4'
        # Defaults (ScopeKind Group, AssignmentScope RecipientGroupScope) and unused management scope
        # naming are left out.
        $parsed.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'ScopeKind'
        $parsed.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'AssignmentScope'
        $parsed.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'ManagementScopePrefix'
        $parsed.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'GroupPrefix'
        $parsed.Rbac.PSObject.Properties.Name      | Should -Not -Contain 'ChangeReference'
        $parsed.Metadata.ChangeReference           | Should -Be 'CHG-JSON'
        $parsed.RbacScope.AccessGroupName  | Should -Be 'USRACo1P-Contoso'
        $parsed.Application.TenantId                   | Should -Be 'tenant-id-123'
        $parsed.PSObject.Properties.Name   | Should -Not -Contain 'TenantId'
        $parsed.Application.AppId          | Should -Be 'app-client-id'
        $parsed.Application.SpObjectId     | Should -Be 'sp-obj-id'
        $parsed.Application.DisplayName    | Should -Be 'Contoso'
        $parsed.Rbac.Roles                 | Should -Contain 'Application Mail.Send'
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
        $content | Should -Match 'SchemaVersion: "4.4"'
        $content | Should -Match 'ScopeKind: "Recipients"'
        $parsed = InModuleScope EXORBACforAppManagement -Parameters @{ Content = $content } { param($Content) ConvertFrom-RBAC4AppYaml -Content $Content }
        $parsed.RbacScope.ScopeKind           | Should -Be 'Recipients'
        $parsed.RbacScope.AssignmentScope     | Should -Be 'ManagementScope'
        $parsed.RbacScope.ManagementScopeName | Should -Be 'Contoso-Scope'
        @($parsed.RbacScope.ScopeRecipients)  | Should -Be @('alice@contoso.com', 'bob@contoso.com')
    }

    It 'defaults to RecipientGroupScope for -ScopeKind Group and round-trips it through YAML' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $TestDrive -Confirm:$false

        $content = Get-Content $outFile -Raw
        $content | Should -Not -Match 'AssignmentScope'
        $parsed = InModuleScope EXORBACforAppManagement -Parameters @{ Content = $content } { param($Content) ConvertFrom-RBAC4AppYaml -Content $Content }
        $parsed.RbacScope.AssignmentScope | Should -Be 'RecipientGroupScope'
    }

    It 'writes ManagementScope when -AssignmentScope ManagementScope is requested' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -AssignmentScope ManagementScope -Format Json `
            -OutputPath $TestDrive -Confirm:$false

        (Get-Content $outFile -Raw | ConvertFrom-Json).RbacScope.AssignmentScope | Should -Be 'ManagementScope'
    }

    It 'rejects -AssignmentScope RecipientGroupScope for a non-Group scope kind' {
        { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Recipients -ScopeRecipients 'alice@contoso.com' `
                -AssignmentScope RecipientGroupScope -OutputPath $TestDrive -Confirm:$false } |
            Should -Throw '*can only be used with -ScopeKind Group*'
    }

    It 'warns that management scope naming is ignored with RecipientGroupScope' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $null = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ManagementScopeName 'Contoso-Scope' `
            -OutputPath $TestDrive -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ';') | Should -Match '-ManagementScopeName only applies to -AssignmentScope ManagementScope'
    }

    It 'writes only the entries the scope kind uses, leaving out defaults and empty values' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $groupFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $TestDrive -Confirm:$false
        $recipientsFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Recipients -ScopeRecipients 'alice@contoso.com' `
            -Members 'ignored@contoso.com' -OutputPath $TestDrive -Confirm:$false -WarningAction SilentlyContinue

        # Every section except Metadata is sparse; Metadata always lists all its keys (empty here).
        $group = Get-Content $groupFile -Raw
        $groupSparse = ($group -split '(?m)^Metadata:')[0]
        $group | Should -Match '(?m)^Metadata:'
        $groupSparse | Should -Not -Match '""'
        $groupSparse | Should -Not -Match ':\s*$'
        foreach ($key in 'ScopeKind', 'AssignmentScope', 'AccessGroupType', 'GroupPrefix', 'Members', 'ManagedBy', 'BootstrapMember',
                         'ManagementScope', 'ScopeRecipients', 'ScopeTag', 'ScopeFilter', 'SeparateScopePerRole', 'ChangeReference') {
            $groupSparse | Should -Not -Match $key
        }
        $group | Should -Match 'AccessGroupName: "USRACo1P-Contoso"'

        $recipients = ((Get-Content $recipientsFile -Raw) -split '(?m)^Metadata:')[0]
        $recipients | Should -Match 'ScopeKind: "Recipients"'
        $recipients | Should -Match 'alice@contoso\.com'
        foreach ($key in 'AssignmentScope', 'AccessGroup', 'GroupPrefix', 'Members', 'ManagedBy', 'BootstrapMember', 'ManagementScope', 'ScopeTag', 'ScopeFilter') {
            $recipients | Should -Not -Match $key
        }

        # Read back, every omitted key takes its default.
        $parsed = InModuleScope EXORBACforAppManagement -Parameters @{ Content = $group } { param($Content) ConvertFrom-RBAC4AppYaml -Content $Content }
        $parsed.RbacScope.ScopeKind             | Should -Be 'Group'
        $parsed.RbacScope.AssignmentScope       | Should -Be 'RecipientGroupScope'
        $parsed.RbacScope.AccessGroupType       | Should -Be 'CloudMailEnabledSecurityGroup'
        $parsed.RbacScope.GroupPrefix           | Should -Be 'USRACo1P'
        @($parsed.RbacScope.Members)            | Should -Be @('GraphAPI-Dummy')
        @($parsed.RbacScope.ManagedBy)          | Should -Be @('GraphAPI-Dummy-owner')
        $parsed.RbacScope.BootstrapMember       | Should -Be 'GraphAPI-Dummy'
        $parsed.RbacScope.ManagementScopePrefix | Should -Be 'MSRAo1P'
        $parsed.RbacScope.ScopeTagAttribute     | Should -Be 'CustomAttribute1'
        $parsed.RbacScope.SeparateScopePerRole  | Should -BeFalse
    }

    It 'round-trips explicit empty Members and BootstrapMember overrides in YAML and JSON' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }

        foreach ($format in 'Yaml', 'Json') {
            $outFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Members @() -BootstrapMember '' `
                -Format $format -OutputPath $TestDrive -Confirm:$false
            $content = Get-Content $outFile -Raw
            if ($format -eq 'Yaml') {
                $parsed = InModuleScope EXORBACforAppManagement -Parameters @{ Content = $content } {
                    param($Content)
                    ConvertFrom-RBAC4AppYaml -Content $Content
                }
                $content | Should -Match 'Members: \[\]'
                $content | Should -Match 'BootstrapMember: ""'
            }
            else {
                $parsed = $content | ConvertFrom-Json
                $parsed = InModuleScope EXORBACforAppManagement -Parameters @{ Config = $parsed } {
                    param($Config)
                    Complete-RBAC4AppConfig -Config $Config
                }
            }

            @($parsed.RbacScope.Members) | Should -BeNullOrEmpty
            $parsed.RbacScope.BootstrapMember | Should -Be ''
        }
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

    It 'rejects -AccessGroupName together with -GroupPrefix' {
        { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -AccessGroupName 'g' -GroupPrefix 'p' -OutputPath $TestDrive -Confirm:$false } |
            Should -Throw '*cannot be used together*'
    }

    It 'requires -ScopeFilter for -ScopeKind Filter' {
        { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Filter -OutputPath $TestDrive -Confirm:$false } |
            Should -Throw '*-ScopeFilter is required*'
    }

    It 'writes the tag and filter scope settings to the config' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        # File names carry only a minute-resolution timestamp, so give each config its own folder.
        $tagDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'tag-scope') -Force
        $filterDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'filter-scope') -Force
        $tagFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Tag -ScopeTagAttribute CustomAttribute3 -ScopeTagValue 'Contoso' `
            -OutputPath $tagDir.FullName -Format Json -Confirm:$false
        $filterFile = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Filter -ScopeFilter "Department -eq 'Sales'" `
            -OutputPath $filterDir.FullName -Format Json -Confirm:$false

        $tag = Get-Content -LiteralPath $tagFile -Raw | ConvertFrom-Json
        $tag.RbacScope.ScopeKind | Should -Be 'Tag'
        $tag.RbacScope.ScopeTagAttribute | Should -Be 'CustomAttribute3'
        $tag.RbacScope.ScopeTagValue | Should -Be 'Contoso'
        $filter = Get-Content -LiteralPath $filterFile -Raw | ConvertFrom-Json
        $filter.RbacScope.ScopeFilter | Should -Be "Department -eq 'Sales'"
    }

    It 'writes an explicit -AccessGroupName and leaves it blank for the hybrid group (legacy name accepted) without one' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $namedDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'named-group') -Force
        $mesgDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'mesg-group') -Force
        $named = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -AccessGroupName 'Custom-Group' -OutputPath $namedDir.FullName -Format Json -Confirm:$false
        $mesg = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -AccessGroupType MailEnabledSecurityGroup -OutputPath $mesgDir.FullName -Format Json -Confirm:$false

        (Get-Content -LiteralPath $named -Raw | ConvertFrom-Json).RbacScope.AccessGroupName | Should -Be 'Custom-Group'
        $mesgConfig = Get-Content -LiteralPath $mesg -Raw | ConvertFrom-Json
        $mesgConfig.RbacScope.AccessGroupType | Should -Be 'HybridMailEnabledSecurityGroup'
        $mesgConfig.RbacScope.PSObject.Properties.Name | Should -Not -Contain 'AccessGroupName'
    }

    It 'writes the YAML config plus a Microsoft365DSC script with -Format M365DSC and returns both paths' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; AppId = '11111111-1111-1111-1111-111111111111'; DisplayName = 'Contoso' }
        }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dsc') -Force
        $files = @(New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Role 'Mail.Send' -ManagedBy 'owner@contoso.com' -OutputPath $dir.FullName -Format M365DSC -Confirm:$false -WarningAction SilentlyContinue)

        $files.Count | Should -Be 2
        $files[0] | Should -Match '\.yml$'
        $files[1] | Should -Be ([System.IO.Path]::ChangeExtension($files[0], '.ps1'))
        $script = Get-Content -LiteralPath $files[1] -Raw
        $script | Should -Match 'Configuration RBAC4App_Contoso'
        $script | Should -Match "EXODistributionGroup 'Group-USRACo1P-Contoso'"
        $script | Should -Match "ManagedBy\s+= @\('owner@contoso.com'\)"
        $script | Should -Match "EXOManagementRoleAssignment 'Assignment-AppMailSend-Contoso'"
        # The YAML is still a normal config and records what DSC does differently.
        $config = InModuleScope EXORBACforAppManagement -Parameters @{ Path = $files[0] } { param($Path) ConvertFrom-RBAC4AppYaml -Content (Get-Content -LiteralPath $Path -Raw) }
        $config.SchemaVersion | Should -Be '4.4'
        $config.RbacScope.AccessGroupName | Should -Be 'USRACo1P-Contoso'
        ($config.Runtime.CollectedWarnings -join ';') | Should -Match 'has no RecipientGroupScope'
    }

    It 'writes certificate sign-in with -DscAuthentication Certificate and rejects it without -Format M365DSC' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; AppId = '11111111-1111-1111-1111-111111111111'; DisplayName = 'Contoso' }
        }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dsc-cert') -Force
        $files = @(New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $dir.FullName -Format M365DSC -DscAuthentication Certificate -Confirm:$false -WarningAction SilentlyContinue)

        $script = Get-Content -LiteralPath $files[1] -Raw
        $script | Should -Match 'CertificateThumbprint = \$CertificateThumbprint'
        $script | Should -Not -Match 'ManagedIdentity'
        { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $dir.FullName -DscAuthentication Certificate -Confirm:$false } | Should -Throw '*only be used with -Format M365DSC*'
    }

    It 'writes neither file with -Format M365DSC -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; AppId = '11111111-1111-1111-1111-111111111111'; DisplayName = 'Contoso' }
        }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dsc-whatif') -Force
        $files = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $dir.FullName -Format M365DSC -WhatIf -WarningAction SilentlyContinue

        $files | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $dir.FullName).Count | Should -Be 0
    }

    It 'warns (and records it) when a group the module creates keeps the default owner' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'owner-warn') -Force
        $warn = $null
        $file = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $dir.FullName -Format Json -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue

        (@($warn | ForEach-Object { [string]$_ }) -join ';') | Should -Match "default owner 'GraphAPI-Dummy-owner'"
        $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        ($config.Runtime.CollectedWarnings -join ';') | Should -Match 'send restriction is skipped'
    }

    It 'does not warn about the owner for an explicit -ManagedBy, a hybrid group, or a non-Group scope kind' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'owner-nowarn') -Force
        $w1 = $null; $w2 = $null; $w3 = $null
        $null = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ManagedBy 'owner@contoso.com' -OutputPath $dir.FullName -Confirm:$false -WarningVariable w1 -WarningAction SilentlyContinue
        $null = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -AccessGroupType HybridMailEnabledSecurityGroup -AccessGroupName 'OnPrem' -OutputPath $dir.FullName -Confirm:$false -WarningVariable w2 -WarningAction SilentlyContinue
        $null = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -ScopeKind Recipients -ScopeRecipients 'a@contoso.com' -OutputPath $dir.FullName -Confirm:$false -WarningVariable w3 -WarningAction SilentlyContinue

        foreach ($w in @($w1, $w2, $w3)) { (@($w | ForEach-Object { [string]$_ }) -join ';') | Should -Not -Match 'default owner' }
    }

    It 'writes into the current directory when -OutputPath is omitted' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cwd-check') -Force
        Push-Location $dir.FullName
        try { $out = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Confirm:$false }
        finally { Pop-Location }

        (Split-Path $out -Parent) | Should -Be $dir.FullName
    }

    It 'writes an empty TenantId when Get-MgContext fails' {
        Mock -ModuleName EXORBACforAppManagement Get-MgContext { throw 'not connected' }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $out = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $TestDrive -Format Json -Confirm:$false

        (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'TenantId'
        (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).Application.PSObject.Properties.Name | Should -Not -Contain 'TenantId'
    }

    It 'errors when AppId matches no service principal' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { @() }
        $err = $null
        $out = New-RBAC4AppConfig -AppId '11111111-1111-1111-1111-111111111111' -OutputPath $TestDrive -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

        $out | Should -BeNullOrEmpty
        ($err -join ';') | Should -Match 'No service principal found for AppId'
    }

    It 'errors when AppId or display name is ambiguous' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            @([pscustomobject]@{ Id = 's1'; AppId = 'a'; DisplayName = 'Contoso' }, [pscustomobject]@{ Id = 's2'; AppId = 'a'; DisplayName = 'Contoso' })
        }
        $e1 = $null; $e2 = $null
        $null = New-RBAC4AppConfig -AppId '11111111-1111-1111-1111-111111111111' -OutputPath $TestDrive -Confirm:$false -ErrorVariable e1 -ErrorAction SilentlyContinue
        $null = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $TestDrive -Confirm:$false -ErrorVariable e2 -ErrorAction SilentlyContinue

        ($e1 -join ';') | Should -Match 'Ambiguous: 2 service principals match AppId'
        ($e2 -join ';') | Should -Match "Ambiguous displayName 'Contoso' matched 2 SPs.*s1, s2"
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

    It 'does not overwrite an earlier config for the same app written to the same folder' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
        }
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'no-overwrite') -Force
        $first = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $dir.FullName -Confirm:$false
        $second = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $dir.FullName -Confirm:$false

        $second | Should -Not -Be $first
        @(Get-ChildItem -LiteralPath $dir.FullName -Filter 'rbac4app-Contoso-*.yml').Count | Should -Be 2
        (Split-Path $first -Leaf) | Should -Match '^rbac4app-Contoso-\d{14}-[0-9a-f]{8}\.yml$'
    }

    Context 'Metadata parameters' {
        BeforeEach {
            Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
                [pscustomobject]@{ Id = 'sp-id'; AppId = 'app-id'; DisplayName = 'Contoso' }
            }
            Mock -ModuleName EXORBACforAppManagement Get-RBAC4AppLocationList { @('HeadOffice', 'DataCenter') }
        }

        It 'writes an empty Metadata section when no metadata parameter is supplied' {
            $file = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Format Json -OutputPath $TestDrive -Confirm:$false

            $metadata = (Get-Content $file -Raw | ConvertFrom-Json).Metadata
            @($metadata.PSObject.Properties).Count | Should -Be 11
            foreach ($property in $metadata.PSObject.Properties) { $property.Value | Should -BeExactly '' }
            Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-RBAC4AppLocationList -Times 0
        }

        It 'writes every supplied field as <Format>, normalizing PCode and location casing' -TestCases @(
            @{ Format = 'Yaml' }
            @{ Format = 'Json' }
        ) {
            param($Format)
            $file = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Format $Format -OutputPath $TestDrive -Confirm:$false `
                -OwnerUsername 'jdoe' -OwnerDisplayName 'Jan Doe' `
                -TechnicalContactUsername 'asmith' -TechnicalContactDisplayName 'Anna Smith' `
                -PCode 'p12345' -CmdbId '11111111-2222-3333-4444-555555555555' `
                -Description 'Runbook: https://wiki.contoso.com/app' `
                -NetworkAccessIP4Range '10.0.0.0/24' -NetworkAccessIP6Range '2001:db8::/32' -NetworkAccessLocation 'headoffice'

            $content = Get-Content $file -Raw
            $parsed = if ($Format -eq 'Json') {
                $content | ConvertFrom-Json
            }
            else {
                InModuleScope EXORBACforAppManagement -Parameters @{ Content = $content } {
                    param($Content)
                    ConvertFrom-RBAC4AppYaml -Content $Content
                }
            }

            $parsed.Metadata.OwnerUsername | Should -Be 'jdoe'
            $parsed.Metadata.OwnerDisplayName | Should -Be 'Jan Doe'
            $parsed.Metadata.TechnicalContactUsername | Should -Be 'asmith'
            $parsed.Metadata.TechnicalContactDisplayName | Should -Be 'Anna Smith'
            $parsed.Metadata.PCode | Should -BeExactly 'P12345'
            $parsed.Metadata.CmdbId | Should -Be '11111111-2222-3333-4444-555555555555'
            $parsed.Metadata.Description | Should -Be 'Runbook: https://wiki.contoso.com/app'
            $parsed.Metadata.NetworkAccessIP4Range | Should -Be '10.0.0.0/24'
            $parsed.Metadata.NetworkAccessIP6Range | Should -Be '2001:db8::/32'
            $parsed.Metadata.NetworkAccessLocation | Should -BeExactly 'HeadOffice'
        }

        It 'accepts <Name> on its own' -TestCases @(
            @{ Name = 'an IPv4 range'; Parameters = @{ NetworkAccessIP4Range = '10.0.0.5' }; Key = 'NetworkAccessIP4Range'; Value = '10.0.0.5' }
            @{ Name = 'an IPv6 range'; Parameters = @{ NetworkAccessIP6Range = '2001:db8::/48' }; Key = 'NetworkAccessIP6Range'; Value = '2001:db8::/48' }
            @{ Name = 'a location';  Parameters = @{ NetworkAccessLocation = 'DataCenter' }; Key = 'NetworkAccessLocation'; Value = 'DataCenter' }
        ) {
            param($Name, $Parameters, $Key, $Value)
            $file = New-RBAC4AppConfig -RegisteredAppName 'Contoso' -Format Json -OutputPath $TestDrive -Confirm:$false @Parameters

            $metadata = (Get-Content $file -Raw | ConvertFrom-Json).Metadata
            @($metadata.PSObject.Properties).Count | Should -Be 11
            @($metadata.PSObject.Properties | Where-Object { $_.Value -ne '' }).Name | Should -Be @($Key)
            $metadata.$Key | Should -Be $Value
        }

        It 'rejects <Name>' -TestCases @(
            @{ Name = 'a PCode with too few digits'; Parameters = @{ PCode = 'P1234' } }
            @{ Name = 'a PCode without the P';       Parameters = @{ PCode = '123456' } }
            @{ Name = 'a CmdbId that is not a GUID'; Parameters = @{ CmdbId = 'not-a-guid' } }
            @{ Name = 'a multi-line Description';    Parameters = @{ Description = "one`ntwo" } }
            @{ Name = 'a Description ending in a newline'; Parameters = @{ Description = "one`n" } }
            @{ Name = 'an out-of-range IP octet';    Parameters = @{ NetworkAccessIP4Range = '999.1.1.1' } }
            @{ Name = 'an out-of-range CIDR prefix'; Parameters = @{ NetworkAccessIP4Range = '1.2.3.4/33' } }
            @{ Name = 'an IPv6 address as IP4Range'; Parameters = @{ NetworkAccessIP4Range = '2001:db8::1' } }
            @{ Name = 'an IPv4 address as IP6Range'; Parameters = @{ NetworkAccessIP6Range = '10.0.0.1' } }
            @{ Name = 'an out-of-range IPv6 prefix'; Parameters = @{ NetworkAccessIP6Range = '2001:db8::/129' } }
            @{ Name = 'an IPv6 zone id';             Parameters = @{ NetworkAccessIP6Range = 'fe80::1%eth0' } }
        ) {
            param($Name, $Parameters)
            { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -OutputPath $TestDrive -Confirm:$false @Parameters } | Should -Throw
            Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 0
        }

        It 'rejects a location that is not in the list, naming the valid ones' {
            { New-RBAC4AppConfig -RegisteredAppName 'Contoso' -NetworkAccessLocation 'Mars' -OutputPath $TestDrive -Confirm:$false } |
                Should -Throw "*Invalid -NetworkAccessLocation 'Mars'. Valid locations: HeadOffice, DataCenter*"
            Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 0
        }
    }

    Context '-Repository state files' {
        BeforeAll {
            $script:stateAppId = '11111111-2222-3333-4444-555555555555'
            $script:newRepository = {
                param([string] $FileName, [string] $Content)
                $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $folder | Out-Null
                if ($FileName) { Set-Content -LiteralPath (Join-Path $folder $FileName) -Value $Content -Encoding UTF8 }
                $folder
            }
            $script:stateYaml = @'
Rbac:
  Roles:
    - "Application Calendars.Read"

RbacScope:
  AccessGroupType: "M365Group"
  AccessGroupName: "Manual-Group"
  Members:
    - "state-member@contoso.com"
  ManagedBy:
    - "state-owner@contoso.com"

Metadata:
  ChangeReference: "CHG-1"
  OwnerUsername: "state-owner"
  PCode: "P11111"
  NetworkAccessLocation: "HeadOffice"
'@
        }

        BeforeEach {
            Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
                [pscustomobject]@{ Id = 'sp-id'; AppId = $script:stateAppId; DisplayName = 'Contoso' }
            }
            Mock -ModuleName EXORBACforAppManagement Get-RBAC4AppLocationList { @('HeadOffice', 'DataCenter') }
            InModuleScope EXORBACforAppManagement -Parameters @{ AppId = $script:stateAppId } {
                param($AppId)
                $script:stateAppId = $AppId
            }
        }

        It 'fills settings missing from the command line from {AppId}<Extension>' -TestCases @(
            @{ Extension = '.yaml' }
            @{ Extension = '.yml' }
        ) {
            param($Extension)
            $repository = & $script:newRepository "$($script:stateAppId)$Extension" $script:stateYaml

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -Format Json -OutputPath $TestDrive -Confirm:$false

            $config = Get-Content $file -Raw | ConvertFrom-Json
            @($config.Rbac.Roles) | Should -Be @('Application Calendars.Read')
            $config.Metadata.ChangeReference | Should -Be 'CHG-1'
            $config.RbacScope.AccessGroupType | Should -Be 'M365Group'
            $config.RbacScope.AccessGroupName | Should -Be 'Manual-Group'
            @($config.RbacScope.Members) | Should -Be @('state-member@contoso.com')
            @($config.RbacScope.ManagedBy) | Should -Be @('state-owner@contoso.com')
            $config.Metadata.OwnerUsername | Should -Be 'state-owner'
            $config.Metadata.PCode | Should -Be 'P11111'
            $config.Metadata.NetworkAccessLocation | Should -Be 'HeadOffice'
        }

        It 'reads a JSON state file' {
            $json = [pscustomobject]@{ Metadata = [pscustomobject]@{ CmdbId = $script:stateAppId } } | ConvertTo-Json -Depth 4
            $repository = & $script:newRepository "$($script:stateAppId).json" $json

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -Format Json -OutputPath $TestDrive -Confirm:$false

            (Get-Content $file -Raw | ConvertFrom-Json).Metadata.CmdbId | Should -Be $script:stateAppId
        }

        It 'lets the command line win and takes the rest from the state file' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $script:stateYaml

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -PCode 'P22222' -Members 'cli@contoso.com' `
                -Format Json -OutputPath $TestDrive -Confirm:$false

            $config = Get-Content $file -Raw | ConvertFrom-Json
            $config.Metadata.PCode | Should -Be 'P22222'
            @($config.RbacScope.Members) | Should -Be @('cli@contoso.com')
            $config.Metadata.OwnerUsername | Should -Be 'state-owner'
        }

        It 'always takes the application identity from Graph, not the state file' {
            $yaml = "Application:`n  DisplayName: `"Stale name`"`n"
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $yaml

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -Format Json -OutputPath $TestDrive -Confirm:$false

            (Get-Content $file -Raw | ConvertFrom-Json).Application.DisplayName | Should -Be 'Contoso'
        }

        It 'does not modify the state file and writes the new config to -OutputPath' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $script:stateYaml
            $statePath = Join-Path $repository "$($script:stateAppId).yaml"
            $before = Get-Content $statePath -Raw
            $output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $output | Out-Null

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -OutputPath $output -Confirm:$false

            Split-Path $file -Parent | Should -Be $output
            Get-Content $statePath -Raw | Should -Be $before
            @(Get-ChildItem -LiteralPath $repository).Count | Should -Be 1
        }

        It 'does not inherit the group name or prefix when -AccessGroupType changes' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $script:stateYaml

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -AccessGroupType DistributionList `
                -Format Json -OutputPath $TestDrive -Confirm:$false

            (Get-Content $file -Raw | ConvertFrom-Json).RbacScope.AccessGroupName | Should -Be 'UDLRAo1P-Contoso'
        }

        It 'prefers -GroupPrefix over the AccessGroupName in the state file' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $script:stateYaml

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -GroupPrefix 'Custom' `
                -Format Json -OutputPath $TestDrive -Confirm:$false

            (Get-Content $file -Raw | ConvertFrom-Json).RbacScope.AccessGroupName | Should -Be 'Custom-Contoso'
        }

        It 'does not inherit AssignmentScope or SeparateScopePerRole when -ScopeKind changes' {
            $yaml = "RbacScope:`n  AssignmentScope: `"ManagementScope`"`n  SeparateScopePerRole: `"true`"`n"
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $yaml

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -ScopeKind Tag -ScopeTagValue 'x' `
                -Format Json -OutputPath $TestDrive -Confirm:$false

            (Get-Content $file -Raw | ConvertFrom-Json).RbacScope.ScopeKind | Should -Be 'Tag'
        }

        It 'inherits SeparateScopePerRole unless -SeparateScopePerRole:$false is passed' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" "RbacScope:`n  SeparateScopePerRole: `"true`"`n"

            $inherited = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -Format Json -OutputPath $TestDrive -Confirm:$false
            $overridden = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -SeparateScopePerRole:$false -Format Json -OutputPath $TestDrive -Confirm:$false

            (Get-Content $inherited -Raw | ConvertFrom-Json).RbacScope.SeparateScopePerRole | Should -BeTrue
            (Get-Content $overridden -Raw | ConvertFrom-Json).RbacScope.PSObject.Properties.Name | Should -Not -Contain 'SeparateScopePerRole'
        }

        It 'keeps an explicit empty Members list from the state file' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" "RbacScope:`n  Members: []`n"

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -Format Json -OutputPath $TestDrive -Confirm:$false

            $scope = (Get-Content $file -Raw | ConvertFrom-Json).RbacScope
            $scope.PSObject.Properties.Name | Should -Contain 'Members'
            @($scope.Members).Count | Should -Be 0
        }

        It 'takes the required values of a ScopeKind from the state file' {
            $yaml = "RbacScope:`n  ScopeKind: `"Recipients`"`n  ScopeRecipients:`n    - `"a@contoso.com`"`n"
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $yaml

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -Format Json -OutputPath $TestDrive -Confirm:$false

            @((Get-Content $file -Raw | ConvertFrom-Json).RbacScope.ScopeRecipients) | Should -Be @('a@contoso.com')
        }

        It 'warns and uses command line values and defaults when the app has no state file' {
            $repository = & $script:newRepository

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -PCode 'P33333' -Format Json `
                -OutputPath $TestDrive -Confirm:$false -WarningVariable warned -WarningAction SilentlyContinue

            ($warned -join ';') | Should -Match 'No state file for AppId'
            (Get-Content $file -Raw | ConvertFrom-Json).Metadata.PCode | Should -Be 'P33333'
        }

        It 'throws before any Graph call when the repository folder does not exist' {
            { New-RBAC4AppConfig -AppId $script:stateAppId -Repository (Join-Path $TestDrive 'missing') -OutputPath $TestDrive -Confirm:$false } |
                Should -Throw '*does not exist*'
            Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipal -Times 0
        }

        It 'throws when the merged settings miss a value the ScopeKind requires' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" "RbacScope:`n  ScopeKind: `"Recipients`"`n"

            { New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -OutputPath $TestDrive -Confirm:$false } |
                Should -Throw '*-ScopeRecipients is required*'
        }

        It 'throws when the state file names a location that is not in the list' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" "Metadata:`n  NetworkAccessLocation: `"Mars`"`n"

            { New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -OutputPath $TestDrive -Confirm:$false } |
                Should -Throw "*Invalid -NetworkAccessLocation 'Mars'*"
        }

        It 'writes an error and no config for <Name>' -TestCases @(
            @{ Name = 'a bad PCode'; FileName = '.yaml'; Content = "Metadata:`n  PCode: `"bad`"`n"; Message = 'Could not use the state file' }
            @{ Name = 'a bad ScopeKind'; FileName = '.yaml'; Content = "RbacScope:`n  ScopeKind: `"Everyone`"`n"; Message = 'Could not use the state file' }
            @{ Name = 'an unsupported schema'; FileName = '.yaml'; Content = "SchemaVersion: `"1.0`"`n"; Message = "unsupported SchemaVersion '1.0'" }
            @{ Name = 'invalid JSON'; FileName = '.json'; Content = '{ not json'; Message = 'could not be parsed' }
            @{ Name = 'a JSON list'; FileName = '.json'; Content = '[{},{}]'; Message = 'contains a list' }
            @{ Name = 'a different AppId in the file'; FileName = '.yaml'; Content = "Application:`n  AppId: `"99999999-2222-3333-4444-555555555555`"`n"; Message = "is for AppId '99999999" }
        ) {
            param($Name, $FileName, $Content, $Message)
            $repository = & $script:newRepository "$($script:stateAppId)$FileName" $Content
            $output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $output | Out-Null

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -OutputPath $output -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

            $file | Should -BeNullOrEmpty
            ($err -join ';') | Should -Match ([regex]::Escape($Message))
            @(Get-ChildItem -LiteralPath $output).Count | Should -Be 0
        }

        It 'writes an error when an app has more than one state file' {
            $repository = & $script:newRepository "$($script:stateAppId).yaml" $script:stateYaml
            Set-Content -LiteralPath (Join-Path $repository "$($script:stateAppId).json") -Value '{}' -Encoding UTF8

            $file = New-RBAC4AppConfig -AppId $script:stateAppId -Repository $repository -OutputPath $TestDrive -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

            $file | Should -BeNullOrEmpty
            ($err -join ';') | Should -Match 'more than one state file'
        }
    }
}
