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
    $script:TailspinScope = 'UDLRAo1P-Tailspin_20d5848c-4d61-4b82-a44f-205adc37321f'

    function Read-RBAC4AppTestConfig {
        param([string] $Path)
        InModuleScope EXORBACforAppManagement -Parameters @{ Path = $Path } {
            ConvertFrom-RBAC4AppYaml -Content (Get-Content -LiteralPath $Path -Raw)
        }
    }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ServicePrincipal', 'Get-ManagementRoleAssignment', 'Get-UnifiedGroup', 'Get-UnifiedGroupLinks', 'Get-DistributionGroup', 'Get-DistributionGroupMember', 'Get-ManagementScope', 'Get-Recipient') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Export-RBAC4AppConfig' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailboxSettings-Tailspin'; EffectiveUserName = $null; App = $null }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroupLinks { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1P-Tailspin') {
                [pscustomobject]@{ DisplayName = $Identity; Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @([pscustomobject]@{ PrimarySmtpAddress = 'shared@tailspin.com'; Name = 'shared' })
        }
    }

    It 'writes a YAML config compatible with Invoke-RBAC4AppConfig using a normalized assignment filename' {
        $rows = @(Get-RBAC4AppEntry)
        $rows | Export-RBAC4AppConfig -Path $TestDrive
        $path = Join-Path $TestDrive 'rbac4app-AppMailboxSettings-Tailspin.yml'

        Test-Path -LiteralPath $path | Should -BeTrue
        $config = Read-RBAC4AppTestConfig $path
        $config.SchemaVersion | Should -Be '4.4'
        $config.Application.DisplayName | Should -Be 'Tailspin'
        $config.Application.AppId | Should -Be '55555555-5555-5555-5555-555555555555'
        $config.Application.SpObjectId | Should -Be '66666666-6666-6666-6666-666666666666'
        @($config.Rbac.Roles) | Should -Be @('Application MailboxSettings.Read')
        $config.RbacScope.ScopeKind | Should -Be 'Group'
        $config.RbacScope.AssignmentScope | Should -Be 'RecipientGroupScope'
        $config.RbacScope.AccessGroupName | Should -Be 'UDLRAo1P-Tailspin'
        $config.RbacScope.AccessGroupType | Should -Be 'DistributionList'
        @($config.RbacScope.Members) | Should -Contain 'shared@tailspin.com'
    }

    It 'writes a Microsoft365DSC script next to the YAML config with -Format M365DSC' {
        $written = @(Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $TestDrive -Format M365DSC -PassThru -WarningAction SilentlyContinue)

        $written.Count | Should -Be 1
        $written[0].Path | Should -Be (Join-Path $TestDrive 'rbac4app-AppMailboxSettings-Tailspin.yml')
        $written[0].DscPath | Should -Be (Join-Path $TestDrive 'rbac4app-AppMailboxSettings-Tailspin.ps1')
        $script = Get-Content -LiteralPath $written[0].DscPath -Raw
        $script | Should -Match 'Configuration RBAC4App_Tailspin'
        $script | Should -Match "EXODistributionGroup 'Group-UDLRAo1P-Tailspin'"
        $script | Should -Match "Type\s+= 'Distribution'"
        $script | Should -Match "Members\s+= @\('GraphAPI-Dummy', 'shared@tailspin.com'\)"
        # A group-bound assignment carries no DN, so the parameter stays mandatory.
        $script | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[System\.String\]\s+\$ScopeGroupDistinguishedName'
        (Read-RBAC4AppTestConfig $written[0].Path).SchemaVersion | Should -Be '4.4'
    }

    It 'pre-fills the group DN in the Microsoft365DSC script for a management-scope bound assignment' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Tailspin'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Tailspin'; EffectiveUserName = $null; App = $null }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = 'MSRAo1P-Tailspin'; RecipientFilter = "MemberOfGroup -eq 'CN=UDLRAo1P-Tailspin,OU=tailspin,DC=prod'" } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ Name = 'UDLRAo1P-Tailspin'; DisplayName = 'UDLRAo1P-Tailspin'; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }

        $written = @(Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $TestDrive -Format M365DSC -PassThru -WarningAction SilentlyContinue)

        $script = Get-Content -LiteralPath $written[0].DscPath -Raw
        $script | Should -Match ([regex]::Escape("`$ScopeGroupDistinguishedName = 'CN=UDLRAo1P-Tailspin,OU=tailspin,DC=prod'"))
        $script | Should -Match "CustomResourceScope = 'MSRAo1P-Tailspin'"
    }

    It 'writes one .ps1 with a uniquely named Configuration per config for a single-file -Path, and nothing under -WhatIf' {
        $rows = @(Get-RBAC4AppEntry)
        $target = Join-Path $TestDrive 'dsc-all.yml'
        $written = @(@($rows[0], $rows[0]) | Export-RBAC4AppConfig -Path $target -Format M365DSC -PassThru -WarningAction SilentlyContinue)

        $written[0].DscPath | Should -Be (Join-Path $TestDrive 'dsc-all.ps1')
        $script = Get-Content -LiteralPath $written[0].DscPath -Raw
        $script | Should -Match 'Configuration RBAC4App_Tailspin\s'
        $script | Should -Match 'Configuration RBAC4App_Tailspin_2\s'

        $whatIfTarget = Join-Path $TestDrive 'dsc-whatif'
        $rows | Export-RBAC4AppConfig -Path "$whatIfTarget\" -Format M365DSC -WhatIf -WarningAction SilentlyContinue
        Test-Path -LiteralPath $whatIfTarget | Should -BeFalse
    }

    It 'passes -DscAuthentication Certificate through and rejects it without -Format M365DSC' {
        $rows = @(Get-RBAC4AppEntry)
        $written = @($rows | Export-RBAC4AppConfig -Path (Join-Path $TestDrive 'cert') -Format M365DSC -DscAuthentication Certificate -PassThru -WarningAction SilentlyContinue)

        $script = Get-Content -LiteralPath $written[0].DscPath -Raw
        $script | Should -Match 'ApplicationId         = \$ApplicationId'
        $script | Should -Not -Match 'ManagedIdentity'
        { $rows | Export-RBAC4AppConfig -Path $TestDrive -DscAuthentication Certificate } | Should -Throw '*only be used with -Format M365DSC*'
    }

    It 'writes nothing to the pipeline without -PassThru, and Path/Config per file with it' {
        $quiet = Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path (Join-Path $TestDrive 'quiet')
        $quiet | Should -BeNullOrEmpty

        $out = @(Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path (Join-Path $TestDrive 'passthru') -PassThru)
        $out.Count | Should -Be 1
        $out[0].Path | Should -Be (Join-Path (Join-Path $TestDrive 'passthru') 'rbac4app-AppMailboxSettings-Tailspin.yml')
        $out[0].Config.Application.AppId | Should -Be '55555555-5555-5555-5555-555555555555'
    }

    It 'writes to the current directory by default' {
        Push-Location -LiteralPath $TestDrive
        try {
            Get-RBAC4AppEntry | Export-RBAC4AppConfig -Format Json
            Test-Path -LiteralPath (Join-Path $TestDrive 'rbac4app-AppMailboxSettings-Tailspin.json') | Should -BeTrue
        }
        finally { Pop-Location }
    }

    It 'resolves a service principal when the assignee name omits the _SP suffix' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
        }

        $errors = @()
        Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $TestDrive -ErrorVariable errors
        $config = Read-RBAC4AppTestConfig (Join-Path $TestDrive 'rbac4app-AppMailboxSettings-Tailspin.yml')

        $errors | Should -BeNullOrEmpty
        $config.Application.AppId | Should -Be '55555555-5555-5555-5555-555555555555'
        $config.Application.SpObjectId | Should -Be '66666666-6666-6666-6666-666666666666'
    }

    Context 'application identity inferred from the role assignment name (D2)' {
        BeforeEach {
            Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
                [pscustomobject]@{ DisplayName = 'api-P00003-sp_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = $null }
            }
            Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
                [pscustomobject]@{
                    Name = 'AppMailSend-api-P00003-sp'; Role = 'Application Mail.Send'
                    RoleAssigneeName = '66666666-6666-6666-6666-666666666666'; RoleAssigneeType = 'ServicePrincipal'
                    EffectiveUserName = '66666666-6666-6666-6666-666666666666'
                    CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true
                }
            }
        }

        It 'reports the row as NameHeuristic and refuses to export it without -Force' {
            $warnings = @()
            $rows = @(Get-RBAC4AppEntry -WarningVariable warnings -WarningAction SilentlyContinue)
            $rows[0].ServicePrincipalIdSource | Should -Be 'NameHeuristic'
            $rows[0].AppId | Should -Be '55555555-5555-5555-5555-555555555555'
            ($warnings -join ';') | Should -Match 'verify the application identity'

            $path = Join-Path $TestDrive 'refused.json'
            $errors = @()
            $rows | Export-RBAC4AppConfig -Path $path -Format Json -ErrorVariable errors -ErrorAction SilentlyContinue

            ($errors -join ';') | Should -Match 'without -Force'
            Test-Path -LiteralPath $path | Should -BeFalse
        }

        It 'exports it with -Force and records why in Runtime.CollectedWarnings' {
            $path = Join-Path $TestDrive 'assignment.json'
            $errors = @()
            Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $path -Format Json -Force -ErrorVariable errors

            $errors | Should -BeNullOrEmpty
            $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $config.Application.AppId | Should -Be '55555555-5555-5555-5555-555555555555'
            $config.Application.SpObjectId | Should -Be '66666666-6666-6666-6666-666666666666'
            ($config.Runtime.CollectedWarnings -join ';') | Should -Match 'verify the application identity'
            ($config.Runtime.CollectedWarnings -join ';') | Should -Match 'inferred from the generated role assignment name'

            $byAppPath = Join-Path $TestDrive 'byapp.json'
            Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -PerApplication -Path $byAppPath -Format Json -Force
            (Get-Content -LiteralPath $byAppPath -Raw | ConvertFrom-Json).Application.AppId | Should -Be '55555555-5555-5555-5555-555555555555'
        }
    }

    It 'does not guess an identity from ambiguous, conflicting, or uncorroborated assignment names, even with -Force' -TestCases @(
        @{ Case = 'ambiguous' }
        @{ Case = 'conflicting' }
        @{ Case = 'ambiguous with object id' }
        @{ Case = 'uncorroborated' }
        @{ Case = 'wrong role name' }
    ) {
        param($Case)
        $script:NameFallbackCase = $Case
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            $id = if ($script:NameFallbackCase -eq 'conflicting') { '77777777-7777-7777-7777-777777777777' } else { $null }
            [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = $id }
            if ($script:NameFallbackCase -in @('ambiguous', 'ambiguous with object id')) {
                $otherId = if ($script:NameFallbackCase -eq 'ambiguous with object id') { '77777777-7777-7777-7777-777777777777' } else { $null }
                [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '88888888-8888-8888-8888-888888888888'; ObjectId = $otherId }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{
                Name = $(if ($script:NameFallbackCase -eq 'wrong role name') { 'AppMailR-Tailspin' } else { 'AppMailSend-Tailspin' })
                Role = 'Application Mail.Send'; RoleAssigneeName = '66666666-6666-6666-6666-666666666666'; RoleAssigneeType = 'ServicePrincipal'
                EffectiveUserName = $(if ($script:NameFallbackCase -eq 'uncorroborated') { '77777777-7777-7777-7777-777777777777' } else { '66666666-6666-6666-6666-666666666666' })
                CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true
            }
        }
        $path = Join-Path $TestDrive "$Case.json"
        $rows = @(Get-RBAC4AppEntry -WarningAction SilentlyContinue)
        $errors = @()
        $rows | Export-RBAC4AppConfig -Path $path -Format Json -Force -ErrorVariable errors -ErrorAction SilentlyContinue

        $rows[0].AppId | Should -BeNullOrEmpty
        ($errors -join ';') | Should -Match 'Cannot export role assignment'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'refuses a name-based match when another assignment for the assignee has a conflicting effective user id' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = $null }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            foreach ($id in @('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777777')) {
                [pscustomobject]@{
                    Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'
                    RoleAssigneeName = '66666666-6666-6666-6666-666666666666'; RoleAssigneeType = 'ServicePrincipal'
                    EffectiveUserName = $id; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true
                }
            }
        }
        $path = Join-Path $TestDrive 'conflicting-assignments.json'
        $rows = @(Get-RBAC4AppEntry -WarningAction SilentlyContinue)
        $errors = @()
        $rows | Export-RBAC4AppConfig -PerApplication -Path $path -Format Json -Force -ErrorVariable errors -ErrorAction SilentlyContinue

        @($rows.AppId | Where-Object { $_ }) | Should -BeNullOrEmpty
        ($errors -join ';') | Should -Match 'Cannot export role assignment'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    Context 'several rows into one file path' {
        BeforeEach {
            Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
                @(
                    [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Contoso_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
                    [pscustomobject]@{ Name = 'AppCldR-Fabrikam'; Role = 'Application Calendars.Read'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
                    [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
                )
            }
        }

        It 'writes all configs as one JSON array, with the extension following -Format' {
            Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path (Join-Path $TestDrive 'inventory.yml') -Format Json
            $path = Join-Path $TestDrive 'inventory.json'

            Test-Path -LiteralPath $path | Should -BeTrue
            $configs = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
            $configs.Count | Should -Be 3
            ($configs | Where-Object { $_.Application.DisplayName -eq 'Contoso' }).Rbac.Roles | Should -Be 'Application Mail.Send'
            $configs.SchemaVersion | Should -Be @('4.4', '4.4', '4.4')
        }

        It 'collects every piped item before writing, so per-item pipeline input is not overwritten (F1)' {
            $path = Join-Path $TestDrive 'piped.json'
            'Contoso', 'Fabrikam' | Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $path -Format Json

            $configs = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
            @($configs.Application.DisplayName | Sort-Object) | Should -Be @('Contoso', 'Fabrikam')
        }
    }

    It 'writes a single application to an explicit file as one config, not an array' {
        $path = Join-Path $TestDrive 'by-application.json'
        Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -Path $path -Format Json

        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $json -is [array] | Should -BeFalse
        @($json.Rbac.Roles) | Should -Be @('Application MailboxSettings.Read')
        $json.Application.DisplayName | Should -Be 'Tailspin'
    }

    It 'exports one config per application holding all of its roles with -PerApplication' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            foreach ($r in 'Mail.Send', 'Mail.Read') {
                [pscustomobject]@{ Name = "App$r-Tailspin"; Role = "Application $r"; RoleAssigneeName = '66666666-6666-6666-6666-666666666666'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
            }
        }
        $dir = Join-Path $TestDrive 'byapp'

        Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -Path $dir

        @(Get-ChildItem -LiteralPath $dir).Name | Should -Be @('rbac4app-Tailspin.yml')
        $config = Read-RBAC4AppTestConfig (Join-Path $dir 'rbac4app-Tailspin.yml')
        @($config.Rbac.Roles) | Should -Be @('Application Mail.Read', 'Application Mail.Send')
        $config.RbacScope.AccessGroupName | Should -Be 'UDLRAo1P-Tailspin'
    }

    It 'splits an application with several distinct scopes into one config per scope' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
            [pscustomobject]@{ Name = 'AppMailR-Tailspin'; Role = 'Application Mail.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'MSRAo1P-Tailspin'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope {
            [pscustomobject]@{ Name = $Identity; RecipientFilter = "PrimarySmtpAddress -eq 'alice@tailspin.com'" }
        }
        $dir = Join-Path $TestDrive 'split'

        Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -Path $dir

        @(Get-ChildItem -LiteralPath $dir | Sort-Object Name).Name | Should -Be @('rbac4app-Tailspin-MSRAo1P-Tailspin.yml', 'rbac4app-Tailspin-UDLRAo1P-Tailspin.yml')
    }

    It 'numbers exported files whose assignment names sanitize to the same file name instead of overwriting' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            foreach ($pair in @(@('App Mail/Send-Tailspin', 'Mail.Send'), @('App Mail:Send-Tailspin', 'Mail.Read'), @('App Mail*Send-Tailspin', 'Calendars.Read'))) {
                [pscustomobject]@{ Name = $pair[0]; Role = "Application $($pair[1])"; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
            }
        }
        $dir = Join-Path $TestDrive 'collide'

        Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $dir

        $files = @(Get-ChildItem -LiteralPath $dir | Sort-Object Name)
        $files.Count | Should -Be 3
        $roles = foreach ($f in $files) { @((Read-RBAC4AppTestConfig $f.FullName).Rbac.Roles) }
        @($roles | Sort-Object) | Should -Be @('Application Calendars.Read', 'Application Mail.Read', 'Application Mail.Send')
    }

    It 'exports recipient-scoped assignments with the resolved recipient list' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'MSRAo1P-Tailspin'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope {
            [pscustomobject]@{ Name = $Identity; RecipientFilter = "PrimarySmtpAddress -eq 'alice@tailspin.com' -or PrimarySmtpAddress -eq 'bob@tailspin.com'" }
        }

        Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $TestDrive
        $config = Read-RBAC4AppTestConfig (Join-Path $TestDrive 'rbac4app-AppMailSend-Tailspin.yml')

        $config.RbacScope.ScopeKind | Should -Be 'Recipients'
        $config.RbacScope.AssignmentScope | Should -Be 'ManagementScope'
        $config.RbacScope.ManagementScopeName | Should -Be 'MSRAo1P-Tailspin'
        @($config.RbacScope.ScopeRecipients) | Should -Be @('alice@tailspin.com', 'bob@tailspin.com')
    }

    It 'exports Tag and Filter scopes, and turns a non-tag Tag filter into a Filter scope' -TestCases @(
        @{ Filter = "CustomAttribute5 -eq 'O''Brien'"; Kind = 'Tag'; Attribute = 'CustomAttribute5'; Value = "O'Brien" }
        @{ Filter = "Department -eq 'Sales'"; Kind = 'Filter'; Attribute = $null; Value = $null }
    ) {
        param($Filter, $Kind, $Attribute, $Value)
        $script:ScopeFilterUnderTest = $Filter
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'MSRAo1P-Tailspin'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { [pscustomobject]@{ Name = $Identity; RecipientFilter = $script:ScopeFilterUnderTest } }
        $dir = Join-Path $TestDrive $Kind

        Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $dir
        $config = Read-RBAC4AppTestConfig (Join-Path $dir 'rbac4app-AppMailSend-Tailspin.yml')

        $config.RbacScope.ScopeKind | Should -Be $Kind
        if ($Kind -eq 'Tag') {
            $config.RbacScope.ScopeTagAttribute | Should -Be $Attribute
            $config.RbacScope.ScopeTagValue | Should -Be $Value
        }
        else {
            $config.RbacScope.ScopeFilter | Should -Be $Filter
        }
    }

    Context 'scope group that cannot be read (D4)' {
        BeforeEach {
            Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
                @(
                    [pscustomobject]@{ Name = 'AppMailR-Gone'; Role = 'Application Mail.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'Um365RAo1-Gone_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true }
                    [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true }
                )
            }
        }

        It 'refuses that config without -Force and still writes the others' {
            $dir = Join-Path $TestDrive 'partial'
            $errors = @()
            Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $dir -ErrorVariable errors -ErrorAction SilentlyContinue

            ($errors -join ';') | Should -Match "scope group 'Um365RAo1-Gone' could not be read"
            ($errors -join ';') | Should -Match '-Force'
            @(Get-ChildItem -LiteralPath $dir).Name | Should -Be @('rbac4app-AppMailboxSettings-Tailspin.yml')
        }

        It 'exports it with -Force as a reference-only HybridMailEnabledSecurityGroup with no members, never guessing the type from the prefix' {
            $dir = Join-Path $TestDrive 'forced'
            $errors = @(); $warn = @()
            Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $dir -Force -ErrorVariable errors -WarningVariable warn -WarningAction SilentlyContinue

            $errors | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 2
            $config = Read-RBAC4AppTestConfig (Join-Path $dir 'rbac4app-AppMailR-Gone.yml')
            $config.RbacScope.AccessGroupName | Should -Be 'Um365RAo1-Gone'
            $config.RbacScope.AccessGroupType | Should -Be 'HybridMailEnabledSecurityGroup'
            # No members written (an empty list is the sparse default; a reference-only group's
            # membership is never touched by Invoke-RBAC4AppConfig anyway).
            (Get-Content -LiteralPath (Join-Path $dir 'rbac4app-AppMailR-Gone.yml') -Raw) | Should -Not -Match '(?m)^\s*Members:'
            ($warn -join ';') | Should -Match 'reference-only'
            ($config.Runtime.CollectedWarnings -join ';') | Should -Match 'reference-only'
            ($config.Runtime.CollectedWarnings -join ';') | Should -Match "Could not resolve scope group 'Um365RAo1-Gone'"
            @($config.Runtime.CollectedErrors).Count | Should -Be 0
        }

        It 'round trip: Invoke-RBAC4AppConfig validates the forced group and never creates it' {
            $dir = Join-Path $TestDrive 'roundtrip'
            Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $dir -Force -WarningAction SilentlyContinue
            $path = Join-Path $dir 'rbac4app-AppMailR-Gone.yml'

            $exo = @{
                'Get-ConnectionInformation' = 'param()'
                'New-ServicePrincipal' = 'param($AppId, $ObjectId, $DisplayName)'
                'New-ManagementRoleAssignment' = 'param($App, $Role, $CustomResourceScope, $RecipientGroupScope, $Name)'
                'New-DistributionGroup' = 'param($Name)'; 'Set-DistributionGroup' = 'param($Identity)'
                'Add-DistributionGroupMember' = 'param($Identity, $Member)'
                'New-UnifiedGroup' = 'param($Name)'; 'Set-UnifiedGroup' = 'param($Identity)'
                'Add-UnifiedGroupLinks' = 'param($Identity, $LinkType, $Links)'
            }
            foreach ($name in $exo.Keys) { Set-Item -Path "Function:\global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($exo[$name])")) }
            try {
                Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { }
                Mock -ModuleName EXORBACforAppManagement Get-Recipient { }
                Mock -ModuleName EXORBACforAppManagement New-ManagementRoleAssignment { [pscustomobject]@{ Name = $Name } }
                $mutatingCmdlets = 'New-DistributionGroup', 'Set-DistributionGroup', 'Add-DistributionGroupMember', 'New-UnifiedGroup', 'Set-UnifiedGroup', 'Add-UnifiedGroupLinks'
                foreach ($mutating in $mutatingCmdlets) {
                    Mock -ModuleName EXORBACforAppManagement $mutating { throw "$($MyInvocation.MyCommand.Name) must not be called for a reference-only group" }
                }

                $result = Invoke-RBAC4AppConfig -Path $path -Confirm:$false -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

                ($result.Errors -join ';') | Should -Match 'Um365RAo1-Gone'
                foreach ($mutating in $mutatingCmdlets) {
                    Should -Invoke -ModuleName EXORBACforAppManagement -CommandName $mutating -Times 0
                }
                Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-ManagementRoleAssignment -Times 0
            }
            finally {
                foreach ($name in $exo.Keys) { Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'honors -WhatIf without writing config files' {
        $whatIfPath = Join-Path $TestDrive 'whatif'
        Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $whatIfPath -WhatIf

        Test-Path -LiteralPath $whatIfPath | Should -BeFalse
    }

    It 'writes an empty Runtime section to an exported config when nothing was collected' {
        Get-RBAC4AppEntry | Export-RBAC4AppConfig -Path $TestDrive -Format Json
        $json = Get-Content -LiteralPath (Join-Path $TestDrive 'rbac4app-AppMailboxSettings-Tailspin.json') -Raw | ConvertFrom-Json

        $json.Runtime.PSObject.Properties.Name | Should -Be @('GeneratedAt', 'OperatorUsername', 'OperatorMachineName', 'CollectedErrors', 'CollectedWarnings')
        $json.Runtime.OperatorMachineName | Should -Be ([System.Environment]::MachineName)
        @($json.Runtime.CollectedErrors).Count | Should -Be 0
        @($json.Runtime.CollectedWarnings).Count | Should -Be 0
    }
}

Describe 'Export-RBAC4AppConfig with an empty service principal object id' {
    BeforeEach {
        $script:FallbackGuid = 'abcdef01-2345-6789-abcd-ef0123456789'
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = '' }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true; EffectiveUserName = $script:FallbackGuid; App = $null }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            if ($Identity -eq 'UDLRAo1P-Tailspin') { [pscustomobject]@{ DisplayName = $Identity; Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            @([pscustomobject]@{ PrimarySmtpAddress = 'shared@tailspin.com'; Name = 'shared' })
        }
    }

    It 'exports the EffectiveUserName object id (no -Force needed) and records the warning in Runtime.CollectedWarnings' {
        $dir = Join-Path $TestDrive 'fallback'
        $errors = @()
        Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $dir -ErrorVariable errors

        $errors | Should -BeNullOrEmpty
        $config = Read-RBAC4AppTestConfig (Join-Path $dir 'rbac4app-AppMailboxSettings-Tailspin.yml')
        $config.Application.SpObjectId | Should -Be $script:FallbackGuid
        @($config.Runtime.CollectedWarnings).Count | Should -Be 1
        $config.Runtime.CollectedWarnings[0] | Should -Match 'from EffectiveUserName'
    }

    It 'refuses to export when neither the pointer nor EffectiveUserName yields an object id' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{ Name = 'AppMailboxSettings-Tailspin'; Role = 'Application MailboxSettings.Read'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true; EffectiveUserName = $null; App = $null }
        }
        $dir = Join-Path $TestDrive 'nofallback'
        $errors = @()
        Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $dir -Force -ErrorVariable errors -ErrorAction SilentlyContinue

        ($errors -join ';') | Should -Match 'could not be resolved'
        Test-Path -LiteralPath $dir | Should -BeFalse
    }
}

Describe 'Export-RBAC4AppConfig failure paths' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:ExoServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
    }

    It 'rejects objects that are not Get-RBAC4AppEntry rows' {
        $errors = @()
        [pscustomobject]@{ Name = 'x'; AppId = '55555555-5555-5555-5555-555555555555' } |
            Export-RBAC4AppConfig -Path (Join-Path $TestDrive 'rejected') -ErrorVariable errors -ErrorAction SilentlyContinue

        ($errors -join ';') | Should -Match 'accepts only Get-RBAC4AppEntry rows'
        Test-Path -LiteralPath (Join-Path $TestDrive 'rejected') | Should -BeFalse
    }

    It 'refuses a non-application role, an unresolved scope, and incomplete scope data' -TestCases @(
        @{ Case = 'role'; Pattern = 'is not an application role' }
        @{ Case = 'scope'; Pattern = 'could not be resolved to a supported config scope' }
        @{ Case = 'recipients'; Pattern = 'Recipients scope data is incomplete' }
    ) {
        param($Case, $Pattern)
        $script:FailureCase = $Case
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            switch ($script:FailureCase) {
                'role' { [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = $script:TailspinScope; RecipientWriteScope = 'Group'; Enabled = $true } }
                'scope' { [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = 'MSRAo1P-Missing'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true } }
                'recipients' { [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomResourceScope = 'MSRAo1P-Tailspin'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true } }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope {
            if ($Identity -eq 'MSRAo1P-Tailspin') { [pscustomobject]@{ Name = $Identity; RecipientFilter = "PrimarySmtpAddress -eq 'x@tailspin.com'" } }
        }
        $rows = @(Get-RBAC4AppEntry -WarningAction SilentlyContinue)
        # Get-RBAC4AppEntry only returns application roles with complete Recipients data, so the
        # remaining cases are produced by editing the row.
        if ($Case -eq 'role') { $rows[0].Role = 'Mail Recipients' }
        if ($Case -eq 'recipients') { $rows[0].ScopeMembers = @() }
        $dir = Join-Path $TestDrive "fail-$Case"
        $errors = @()
        $rows | Export-RBAC4AppConfig -Path $dir -Force -ErrorVariable errors -ErrorAction SilentlyContinue

        ($errors -join ';') | Should -Match $Pattern
        Test-Path -LiteralPath $dir | Should -BeFalse
    }
}
