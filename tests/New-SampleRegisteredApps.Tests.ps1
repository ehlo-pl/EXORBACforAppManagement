#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:sampleScript = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'scripts') 'New-SampleRegisteredApps.ps1'

    function global:Get-MgContext { }
    function global:Get-MgServicePrincipal { param($Filter, $Property, $ErrorAction) }
    function global:New-MgApplication { param($DisplayName, $SignInAudience, $RequiredResourceAccess, $ErrorAction) }
    function global:New-MgServicePrincipal { param($AppId, $ErrorAction) }
    function global:New-MgServicePrincipalAppRoleAssignment { param($ServicePrincipalId, $PrincipalId, $ResourceId, $AppRoleId, $ErrorAction) }
}

AfterAll {
    Remove-Variable SampleCreatedApps, SampleCreatedAssignments -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in 'Get-MgContext', 'Get-MgServicePrincipal', 'New-MgApplication', 'New-MgServicePrincipal', 'New-MgServicePrincipalAppRoleAssignment') {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'New-SampleRegisteredApps.ps1' {
    BeforeEach {
        $global:SampleCreatedApps = [System.Collections.Generic.List[object]]::new()
        $global:SampleCreatedAssignments = [System.Collections.Generic.List[object]]::new()

        Mock Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1' } }
        Mock Get-MgServicePrincipal {
            [pscustomobject]@{
                Id = 'graph-service-principal'
                AppRoles = @(
                    [pscustomobject]@{ Value = 'Mail.Send'; Id = 'role-mail-send'; IsEnabled = $true; AllowedMemberTypes = @('Application') }
                    [pscustomobject]@{ Value = 'Mail.ReadWrite'; Id = 'role-mail-readwrite'; IsEnabled = $true; AllowedMemberTypes = @('Application') }
                    [pscustomobject]@{ Value = 'Calendars.ReadWrite'; Id = 'role-calendar-readwrite'; IsEnabled = $true; AllowedMemberTypes = @('Application') }
                )
            }
        }
        Mock New-MgApplication {
            $global:SampleCreatedApps.Add([pscustomobject]@{
                DisplayName = $DisplayName
                RequiredResourceAccess = @($RequiredResourceAccess)
            })
            [pscustomobject]@{ AppId = [guid]::NewGuid().ToString(); Id = [guid]::NewGuid().ToString() }
        }
        Mock New-MgServicePrincipal { [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } }
        Mock New-MgServicePrincipalAppRoleAssignment {
            $global:SampleCreatedAssignments.Add([pscustomobject]@{
                ServicePrincipalId = $ServicePrincipalId
                PrincipalId = $PrincipalId
                ResourceId = $ResourceId
                AppRoleId = $AppRoleId
            })
        }
    }

    It 'creates equal groups for all four permission profiles and grants only the requested roles' {
        $results = @(& $script:sampleScript -Confirm:$false)

        $results.Count | Should -Be 140
        ($results | Group-Object PermissionProfile | Sort-Object Name | ForEach-Object Count) |
            Should -Be @(35, 35, 35, 35)
        $global:SampleCreatedApps.Count | Should -Be 140
        $global:SampleCreatedAssignments.Count | Should -Be 140
        ($results.DisplayName | Sort-Object -Unique).Count | Should -Be 140
        ($results | Where-Object PermissionProfile -eq 'Mail.Send and Mail.ReadWrite' |
            Select-Object -First 1 -ExpandProperty Permissions) |
            Should -Be @('Mail.Send', 'Mail.ReadWrite')
        ($results | Where-Object PermissionProfile -eq 'No Microsoft Graph application permissions' |
            Select-Object -First 1 -ExpandProperty Permissions) |
            Should -BeNullOrEmpty
        @($global:SampleCreatedApps | Where-Object { $_.RequiredResourceAccess.Count -eq 0 }).Count |
            Should -Be 35
        $global:SampleCreatedApps[0].RequiredResourceAccess[0].ResourceAppId |
            Should -Be '00000003-0000-0000-c000-000000000000'
        $global:SampleCreatedApps[0].RequiredResourceAccess[0].ResourceAccess[0].Id |
            Should -Be 'role-mail-send'
        $global:SampleCreatedApps[35].RequiredResourceAccess[0].ResourceAccess.Id |
            Should -Be @('role-mail-send', 'role-mail-readwrite')
        $global:SampleCreatedApps[70].RequiredResourceAccess[0].ResourceAccess[0].Id |
            Should -Be 'role-calendar-readwrite'
        @($global:SampleCreatedAssignments | Where-Object ResourceId -ne 'graph-service-principal').Count |
            Should -Be 0
        @($global:SampleCreatedAssignments | Where-Object AppRoleId -eq 'role-mail-send').Count |
            Should -Be 70
        @($global:SampleCreatedAssignments | Where-Object AppRoleId -eq 'role-mail-readwrite').Count |
            Should -Be 35
        @($global:SampleCreatedAssignments | Where-Object AppRoleId -eq 'role-calendar-readwrite').Count |
            Should -Be 35
    }

    It 'does not create applications when run with -WhatIf' {
        $results = @(& $script:sampleScript -WhatIf)

        $results | Should -BeNullOrEmpty
        $global:SampleCreatedApps.Count | Should -Be 0
        $global:SampleCreatedAssignments.Count | Should -Be 0
    }

    It 'rejects a count that cannot be split evenly across the profiles' {
        { & $script:sampleScript -Count 5 -Confirm:$false } | Should -Throw '*divisible by four*'
        Should -Invoke Get-MgContext -Times 0
    }
}
