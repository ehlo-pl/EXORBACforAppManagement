#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Error/edge-path coverage for Invoke-MsGraphEntraIDApiPerm; the happy paths live in
# Resolve-ApplicationAccessPolicy.Tests.ps1 next to the export they enrich.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-MgServicePrincipal { [CmdletBinding()] param([string]$Filter) }
    function global:Get-MgServicePrincipalAppRoleAssignment { [CmdletBinding()] param([string]$ServicePrincipalId) }

    $script:AppId = '11111111-1111-1111-1111-111111111111'
    $script:NewExport = {
        param($Name)
        $path = Join-Path $TestDrive $Name
        [pscustomobject]@{
            Policies = @([pscustomobject]@{
                ScopeName = 'Scope'; ScopeIdentity = 'scope@contoso.com'; AppId = $script:AppId
                AccessRight = 'RestrictAccess'; Group = 'Scope'; Permissions = @()
            })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path
        $path
    }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-MgServicePrincipal', 'Get-MgServicePrincipalAppRoleAssignment') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-MsGraphEntraIDApiPerm error handling' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            if ($Filter -like '*00000003-0000-0000-c000-000000000000*') {
                [pscustomobject]@{ Id = 'graph-resource'; AppRoles = @([pscustomobject]@{ Id = 'mail-read'; Value = 'Mail.Read' }) }
            }
            else { [pscustomobject]@{ Id = 'app-sp'; AppId = $script:AppId } }
        }
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment {
            @([pscustomobject]@{ AppRoleId = 'mail-read'; ResourceId = 'graph-resource' })
        }
    }

    It 'writes an error for an unsupported file extension' {
        $path = Join-Path $TestDrive 'export.txt'
        Set-Content -LiteralPath $path -Value 'x'
        $err = $null
        $res = Invoke-MsGraphEntraIDApiPerm -Path $path -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

        $res | Should -BeNullOrEmpty
        ($err -join ';') | Should -Match "Unsupported policy file extension '.txt'"
    }

    It 'writes an error for a file that cannot be parsed' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{ not json'
        $err = $null
        $res = Invoke-MsGraphEntraIDApiPerm -Path $path -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

        $res | Should -BeNullOrEmpty
        ($err -join ';') | Should -Match 'Failed to read Application Access Policy export'
    }

    It 'reports an error and stops when the Microsoft Graph service principal is not unique' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal { @() }
        $res = Invoke-MsGraphEntraIDApiPerm -Path (& $script:NewExport 'no-graph.json') -Confirm:$false

        $res.Errors | Should -Contain 'Expected one Microsoft Graph service principal but found 0.'
        $res.OutputPath | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipalAppRoleAssignment -Times 0
    }

    It 'reports an error and leaves Permissions empty when the app service principal is not unique' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipal {
            if ($Filter -like '*00000003-0000-0000-c000-000000000000*') { [pscustomobject]@{ Id = 'graph-resource'; AppRoles = @() } }
        }
        $res = Invoke-MsGraphEntraIDApiPerm -Path (& $script:NewExport 'no-app.json') -Confirm:$false

        ($res.Errors -join ';') | Should -Match "Expected one service principal for AppId '$script:AppId' but found 0"
        $res.Policies[0].Permissions | Should -BeNullOrEmpty
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-MgServicePrincipalAppRoleAssignment -Times 0
    }

    It 'reports an error when the Graph permissions cannot be read' {
        Mock -ModuleName EXORBACforAppManagement Get-MgServicePrincipalAppRoleAssignment { throw 'Forbidden' }
        $res = Invoke-MsGraphEntraIDApiPerm -Path (& $script:NewExport 'forbidden.json') -Confirm:$false

        ($res.Errors -join ';') | Should -Match "Failed to read Graph permissions for AppId '$script:AppId': Forbidden"
        $res.Policies[0].Permissions | Should -BeNullOrEmpty
    }

    It 'writes to an explicit -OutputPath' {
        $out = Join-Path $TestDrive 'explicit-output.json'
        $res = Invoke-MsGraphEntraIDApiPerm -Path (& $script:NewExport 'explicit.json') -OutputPath $out -Confirm:$false

        $res.OutputPath | Should -Be $out
        (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).Policies[0].Permissions | Should -Be 'Mail.Read'
    }

    It 'reports an error when the output file cannot be written' {
        $out = Join-Path $TestDrive 'missing-dir' 'out.json'
        $res = Invoke-MsGraphEntraIDApiPerm -Path (& $script:NewExport 'unwritable.json') -OutputPath $out -Confirm:$false

        $res.OutputPath | Should -BeNullOrEmpty
        $res.Errors | Should -Not -BeNullOrEmpty
    }

    It 'does not write the output file under -WhatIf' {
        $out = Join-Path $TestDrive 'whatif-output.json'
        $res = Invoke-MsGraphEntraIDApiPerm -Path (& $script:NewExport 'whatif.json') -OutputPath $out -WhatIf

        $res.OutputPath | Should -BeNullOrEmpty
        Test-Path -LiteralPath $out | Should -BeFalse
    }
}
