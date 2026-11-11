#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Golden-file characterization of Get-RBAC4AppEntry (per-assignment rows and warnings),
# Get-RBAC4AppApplication (per-application rows), and Export-RBAC4AppConfig (YAML/JSON configs for
# every scope kind). Created in Phase 0 of plans/GET-RBAC4APPENTRY_REBUILD_PLAN.md against 0.8.x
# and regenerated deliberately for 0.9.0 (new row properties, F10, and the -Force rule for an
# unreadable scope group).
#
# Golden files live in tests/fixtures/Get-RBAC4AppEntry. To (re)create them, run this file with
#   $env:RBAC4APP_UPDATE_GOLDEN = '1'
# then review the diff before committing. Line endings are normalized to LF on both sides, and
# the volatile Runtime fields (GeneratedAt, OperatorUsername, OperatorMachineName) are masked.

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

    $script:GoldenDir = Join-Path $PSScriptRoot 'fixtures' 'Get-RBAC4AppEntry'

    function Assert-RBAC4AppGolden {
        param([string] $Name, [string] $Actual)
        $normalize = { param([string] $Text) (($Text -replace "`r`n", "`n").TrimEnd()) + "`n" }
        $actualText = & $normalize $Actual
        $path = Join-Path $script:GoldenDir $Name
        if ($env:RBAC4APP_UPDATE_GOLDEN) {
            $null = New-Item -ItemType Directory -Path $script:GoldenDir -Force
            [System.IO.File]::WriteAllText($path, $actualText, [System.Text.UTF8Encoding]::new($false))
            return
        }
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Golden file '$Name' is missing. Run with `$env:RBAC4APP_UPDATE_GOLDEN = '1' to create it, then review it."
        }
        $actualText | Should -BeExactly (& $normalize ([System.IO.File]::ReadAllText($path)))
    }

    function ConvertTo-RBAC4AppMaskedConfig {
        param([string] $Text)
        $Text -replace '(?m)^(\s*"?(?:GeneratedAt|OperatorUsername|OperatorMachineName)"?\s*:\s*)"[^"]*"', '$1"<masked>"'
    }

    $guid = { param([int] $N) [guid]('00000000-0000-0000-0000-{0:D12}' -f $N) }

    # One assignment per scope kind the module reads, plus one whose scope group cannot be read.
    $script:CharAssignments = @(
        [pscustomobject]@{ Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = '22222222-2222-2222-2222-222222222222'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = (& $guid 1); Identity = 'AppMailSend-Contoso'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailR-Contoso'; Role = 'Application Mail.Read'; RoleAssigneeName = '22222222-2222-2222-2222-222222222222'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Contoso'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $false; Guid = (& $guid 2); Identity = 'AppMailR-Contoso'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailSend-Fabrikam'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Fabrikam_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Fabrikam'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = (& $guid 3); Identity = 'AppMailSend-Fabrikam'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailSend-Tailspin'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Tailspin_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Tailspin'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = (& $guid 4); Identity = 'AppMailSend-Tailspin'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailSend-Northwind'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Northwind_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'MSRAo1P-Northwind'; RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = (& $guid 5); Identity = 'AppMailSend-Northwind'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppCldR-Litware'; Role = 'Application Calendars.Read'; RoleAssigneeName = 'Litware_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'USRAo1P-Litware_20d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true; Guid = (& $guid 6); Identity = 'AppCldR-Litware'; EffectiveUserName = $null; App = $null }
        [pscustomobject]@{ Name = 'AppMailSend-Adatum'; Role = 'Application Mail.Send'; RoleAssigneeName = 'Adatum_SP'; RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = $null; CustomResourceScope = 'Um365RAo1P-Adatum_30d5848c-4d61-4b82-a44f-205adc37321f'; RecipientWriteScope = 'Group'; Enabled = $true; Guid = (& $guid 7); Identity = 'AppMailSend-Adatum'; EffectiveUserName = $null; App = $null }
    )

    $script:CharServicePrincipals = @(
        [pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' }
        [pscustomobject]@{ DisplayName = 'Fabrikam_SP'; AppId = '33333333-3333-3333-3333-333333333333'; ObjectId = '44444444-4444-4444-4444-444444444444' }
        [pscustomobject]@{ DisplayName = 'Tailspin_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = '66666666-6666-6666-6666-666666666666' }
        [pscustomobject]@{ DisplayName = 'Northwind_SP'; AppId = '77777777-7777-7777-7777-777777777777'; ObjectId = '88888888-8888-8888-8888-888888888888' }
        [pscustomobject]@{ DisplayName = 'Litware_SP'; AppId = '99999999-9999-9999-9999-999999999999'; ObjectId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        [pscustomobject]@{ DisplayName = 'Adatum_SP'; AppId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; ObjectId = 'cccccccc-cccc-cccc-cccc-cccccccccccc' }
    )
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ServicePrincipal', 'Get-ManagementRoleAssignment', 'Get-UnifiedGroup', 'Get-UnifiedGroupLinks', 'Get-DistributionGroup', 'Get-DistributionGroupMember', 'Get-ManagementScope', 'Get-Recipient') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RBAC4AppEntry characterization (golden files)' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:CharAssignments }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:CharServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope {
            switch ($Identity) {
                'MSRAo1P-Contoso'   { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(MemberOfGroup -eq 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod')" } }
                'MSRAo1P-Fabrikam'  { [pscustomobject]@{ Name = $Identity; RecipientFilter = "((PrimarySmtpAddress -eq 'bob@fabrikam.com') -or (PrimarySmtpAddress -eq 'alice@fabrikam.com'))" } }
                'MSRAo1P-Tailspin'  { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(CustomAttribute5 -eq 'TailspinApp')" } }
                'MSRAo1P-Northwind' { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(Department -eq 'Sales')" } }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            if ($PesterBoundParameters.ContainsKey('RecipientPreviewFilter')) {
                switch ($RecipientPreviewFilter) {
                    "(CustomAttribute5 -eq 'TailspinApp')" { @([pscustomobject]@{ PrimarySmtpAddress = 'tagged@tailspin.com'; Name = 'tagged' }) }
                    "(Department -eq 'Sales')" { @([pscustomobject]@{ PrimarySmtpAddress = 'sales2@northwind.com'; Name = 'sales2' }, [pscustomobject]@{ PrimarySmtpAddress = 'sales1@northwind.com'; Name = 'sales1' }) }
                }
            }
            # $PesterBoundParameters, not $Identity: the -Anr call leaves $Identity unset, which
            # fails under the build's Set-StrictMode -Version Latest.
            elseif ($PesterBoundParameters['Identity'] -eq 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod') {
                [pscustomobject]@{ Name = 'UDLRAo1P-Contoso'; DisplayName = 'UDLRAo1P-Contoso' }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            switch ($Identity) {
                'UDLRAo1P-Contoso' { [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }
                'USRAo1P-Litware'  { [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalSecurityGroup' } }
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember {
            switch ($Identity) {
                'UDLRAo1P-Contoso' { @([pscustomobject]@{ PrimarySmtpAddress = 'shared@contoso.com'; Name = 'shared' }) }
                'USRAo1P-Litware'  { @([pscustomobject]@{ PrimarySmtpAddress = 'cal@litware.com'; Name = 'cal' }) }
            }
        }
    }

    It 'per-assignment rows' {
        $rows = @(Get-RBAC4AppEntry -WarningAction SilentlyContinue)
        $rows.Count | Should -Be 7
        Assert-RBAC4AppGolden -Name 'rows.json' -Actual (ConvertTo-Json -InputObject $rows -Depth 5)
    }

    It 'per-assignment warnings' {
        $warnings = @()
        $null = Get-RBAC4AppEntry -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-RBAC4AppGolden -Name 'rows-warnings.txt' -Actual (($warnings | ForEach-Object { [string]$_ }) -join "`n")
    }

    It 'per-application rows (Get-RBAC4AppApplication)' {
        $rows = @(Get-RBAC4AppApplication -WarningAction SilentlyContinue)
        $rows.Count | Should -Be 6
        Assert-RBAC4AppGolden -Name 'byapplication.json' -Actual (ConvertTo-Json -InputObject $rows -Depth 5)
    }

    It 'refuses only the unreadable scope group without -Force' {
        $dir = Join-Path $TestDrive 'no-force'
        $errors = @()
        Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $dir -ErrorVariable errors -ErrorAction SilentlyContinue
        @($errors).Count | Should -Be 1
        "$($errors[0])" | Should -Match "AppMailSend-Adatum.*'Um365RAo1P-Adatum' could not be read"
        @(Get-ChildItem -LiteralPath $dir -File).Count | Should -Be 6
    }

    It 'exported YAML config per assignment, for every scope kind (-Force)' {
        $dir = Join-Path $TestDrive 'per-assignment'
        $errors = @()
        Get-RBAC4AppEntry -WarningAction SilentlyContinue | Export-RBAC4AppConfig -Path $dir -Force -ErrorVariable errors -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        $errors | Should -BeNullOrEmpty

        $files = @(Get-ChildItem -LiteralPath $dir -File | Sort-Object Name)
        Assert-RBAC4AppGolden -Name 'export-files.txt' -Actual (($files.Name) -join "`n")
        foreach ($file in $files) {
            Assert-RBAC4AppGolden -Name ("export-{0}" -f $file.Name) -Actual (ConvertTo-RBAC4AppMaskedConfig ([System.IO.File]::ReadAllText($file.FullName)))
        }
    }

    It 'exported JSON config per application into a single file path' {
        $path = Join-Path $TestDrive 'contoso.json'
        Get-RBAC4AppEntry -RegisteredAppName 'Contoso' -WarningAction SilentlyContinue | Export-RBAC4AppConfig -PerApplication -Path $path -Format Json
        Assert-RBAC4AppGolden -Name 'export-byapplication-contoso.json' -Actual (ConvertTo-RBAC4AppMaskedConfig ([System.IO.File]::ReadAllText($path)))
    }
}
