#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Export-RBAC4AppStateReport' {
    BeforeAll {
        $script:reportScript = Join-Path $PSScriptRoot '..' 'scripts' 'Export-RBAC4AppStateReport.ps1'

        $script:writeState = {
            param([string] $Folder, [hashtable] $Files)
            $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive $Folder) -Force
            foreach ($name in $Files.Keys) {
                $target = Join-Path $dir.FullName $name
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                $Files[$name] | Set-Content -LiteralPath $target -Encoding UTF8
            }
            $dir.FullName
        }
    }

    It 'scans YAML files recursively and reports values under their schema path' {
        $stateFolder = & $script:writeState 'state' @{
            'app.yaml' = @'
SchemaVersion: "4.3"
TenantId: "tenant-id"

Application:
  AppId: "app-id"
  SpObjectId: "sp-id"
  DisplayName: "Contoso App"

Rbac:
  Roles:
    - "Application Mail.Send"
    - "Application Calendars.Read"

RbacScope:
  ScopeKind: "Recipients"
  ScopeRecipients:
    - "a@contoso.com"
    - "b@contoso.com"

Metadata:
  OwnerUsername: "owner@contoso.com"
  PCode: "P12345"
  Description: "Mail, calendar"
  NetworkAccessIP6Range: "2001:db8::/32"
  NetworkAccessLocation: "Worldwide"

ConversionResult:
  AppId: "app-id"
  AccessRight: "RestrictAccess"
  ScopeGroup: "EvenUsers"
  DerivedRoles:
    - "Application Mail.Send"
  SkippedPermissions: []
  ConfigPath: "C:\\state\\app.yaml"

Runtime:
  GeneratedAt: "2026-11-06T09:00:00Z"
  OperatorUsername: "CONTOSO\\jdoe"
  OperatorMachineName: "WS01"
  CollectedErrors: []
  CollectedWarnings:
    - "w1"
'@
            'nested/other.yml' = @'
SchemaVersion: "4.1"
GeneratedAt: "2026-01-01T00:00:00Z"

Application:
  AppId: "other-app-id"
  DisplayName: "Other App"

Metadata:
  CmdbId: "cmdb-123"
  NetworkAccessIPRange: "10.0.0.0/24"
'@
            'ignored.json' = '{"SchemaVersion":"4.2","Application":{"AppId":"ignored"}}'
        }
        $outputPath = Join-Path $TestDrive 'report.csv'

        $result = & $script:reportScript -Path $stateFolder -OutputPath $outputPath
        $rows = @(Import-Csv -LiteralPath $outputPath)

        $result | Should -Be $outputPath
        $rows.Count | Should -Be 2
        $first = $rows | Where-Object 'Application.AppId' -eq 'app-id'
        $first.SchemaVersion | Should -Be '4.3'
        $first.'Runtime.GeneratedAt' | Should -Be '2026-11-06T09:00:00Z'
        $first.'ConversionResult.AccessRight' | Should -Be 'RestrictAccess'
        $first.'ConversionResult.DerivedRoles' | Should -Be 'Application Mail.Send'
        $first.'ConversionResult.SkippedPermissions' | Should -BeExactly ''
        $first.'ConversionResult.ConfigPath' | Should -Be 'C:\state\app.yaml'
        $first.'ConversionResult.ResolvedDisplay' | Should -BeExactly ''
        $first.'Application.DisplayName' | Should -Be 'Contoso App'
        $first.'Rbac.Roles' | Should -Be 'Application Mail.Send; Application Calendars.Read'
        $first.'RbacScope.ScopeKind' | Should -Be 'Recipients'
        $first.'RbacScope.ScopeRecipients' | Should -Be 'a@contoso.com; b@contoso.com'
        $first.'Metadata.OwnerUsername' | Should -Be 'owner@contoso.com'
        $first.'Metadata.Description' | Should -Be 'Mail, calendar'
        $first.'Metadata.NetworkAccessLocation' | Should -Be 'Worldwide'
        $first.'Metadata.NetworkAccessIP6Range' | Should -Be '2001:db8::/32'
        $first.'Metadata.NetworkAccessIP4Range' | Should -BeExactly ''
        $first.'Runtime.OperatorUsername' | Should -Be 'CONTOSO\jdoe'
        $first.'Runtime.OperatorMachineName' | Should -Be 'WS01'
        $first.'Runtime.CollectedErrors' | Should -BeExactly ''
        $first.'Runtime.CollectedWarnings' | Should -Be 'w1'

        $second = $rows | Where-Object 'Application.AppId' -eq 'other-app-id'
        $second.SchemaVersion | Should -Be '4.1'
        $second.'Metadata.CmdbId' | Should -Be 'cmdb-123'
        # Before the IPv4/IPv6 split NetworkAccessIPRange was IPv4-only; it is reported as IP4Range.
        $second.'Metadata.NetworkAccessIP4Range' | Should -Be '10.0.0.0/24'
        # Before 4.3 GeneratedAt was a top-level key; it is reported as Runtime.GeneratedAt.
        $second.'Runtime.GeneratedAt' | Should -Be '2026-01-01T00:00:00Z'
    }

    It 'writes every schema field as a column, empty (not defaulted) when the file omits it' {
        $stateFolder = & $script:writeState 'minimal' @{
            'app.yaml' = @'
SchemaVersion: "4.3"
Application:
  AppId: "app-id"
'@
        }
        $outputPath = Join-Path $TestDrive 'minimal.csv'

        $null = & $script:reportScript -Path $stateFolder -OutputPath $outputPath
        $row = @(Import-Csv -LiteralPath $outputPath)[0]

        foreach ($column in $row.PSObject.Properties) {
            if ($column.Name -in @('File', 'SchemaVersion', 'Application.AppId')) { continue }
            $column.Value | Should -BeExactly '' -Because "$($column.Name) is not in the file"
        }
        # Defaults are not filled in.
        $row.'RbacScope.ScopeKind' | Should -BeExactly ''
        $row.'RbacScope.Members' | Should -BeExactly ''
        $row.'RbacScope.SeparateScopePerRole' | Should -BeExactly ''
    }

    It 'covers exactly the schema fields, in schema order after File' {
        $stateFolder = & $script:writeState 'columns' @{ 'app.yaml' = "SchemaVersion: `"4.3`"`nApplication:`n  AppId: `"app-id`"" }
        $outputPath = Join-Path $TestDrive 'columns.csv'

        $null = & $script:reportScript -Path $stateFolder -OutputPath $outputPath
        $header = (Get-Content -LiteralPath $outputPath -TotalCount 1) -replace '"', ''
        $columns = $header -split ','

        # The completed config shape is the full set of schema fields; Rbac.ChangeReference is the
        # legacy location Complete-RBAC4AppConfig folds into Metadata.ChangeReference.
        $expected = InModuleScope EXORBACforAppManagement {
            $full = Complete-RBAC4AppConfig -Config ([pscustomobject]@{ SchemaVersion = '4.3' })
            foreach ($property in $full.PSObject.Properties) {
                if ($property.Value -is [pscustomobject]) {
                    foreach ($child in $property.Value.PSObject.Properties) { "$($property.Name).$($child.Name)" }
                }
                else { $property.Name }
            }
        }
        $columns[0] | Should -Be 'File'
        @($columns | Select-Object -Skip 1 | Where-Object { $_ -ne 'Rbac.ChangeReference' } | Sort-Object) |
            Should -Be @($expected | Sort-Object)
        $columns | Should -Contain 'Rbac.ChangeReference'
        $columns.IndexOf('Application.AppId') | Should -BeLessThan $columns.IndexOf('Metadata.PCode')
        $columns.IndexOf('Metadata.PCode') | Should -BeLessThan $columns.IndexOf('Runtime.OperatorUsername')
    }

    It 'shows an explicitly empty Members override as []' {
        $stateFolder = & $script:writeState 'members' @{
            'app.yaml' = @'
SchemaVersion: "4.3"
Application:
  AppId: "app-id"
RbacScope:
  Members: []
  SeparateScopePerRole: "true"
'@
        }
        $outputPath = Join-Path $TestDrive 'members.csv'

        $null = & $script:reportScript -Path $stateFolder -OutputPath $outputPath
        $row = @(Import-Csv -LiteralPath $outputPath)[0]

        $row.'RbacScope.Members' | Should -Be '[]'
        $row.'RbacScope.SeparateScopePerRole' | Should -Be 'true'
    }

    It 'does not write the report with -WhatIf' {
        $stateFolder = & $script:writeState 'whatif-state' @{ 'app.yaml' = "SchemaVersion: `"4.3`"`nApplication:`n  AppId: `"app-id`"" }
        $outputPath = Join-Path $TestDrive 'whatif.csv'

        & $script:reportScript -Path $stateFolder -OutputPath $outputPath -WhatIf

        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }

    It 'skips YAML files that are not state files (e.g. policy exports) with a warning' {
        $stateFolder = & $script:writeState 'mixed' @{
            'app.yaml' = "SchemaVersion: `"4.3`"`nApplication:`n  AppId: `"app-id`""
            'sub/exo-application-access-policies-1.yml' = @'
Policies:
  - ScopeName: "USRAo1P-x"
    AppId: "c006b17b-f094-4449-87e6-735c52fc8d4c"
    AccessRight: "RestrictAccess"
    Permissions: []
'@
        }
        $outputPath = Join-Path $TestDrive 'mixed.csv'

        $warn = @()
        $null = & $script:reportScript -Path $stateFolder -OutputPath $outputPath -WarningVariable warn -WarningAction SilentlyContinue
        $rows = @(Import-Csv -LiteralPath $outputPath)

        $rows.Count | Should -Be 1
        $rows[0].'Application.AppId' | Should -Be 'app-id'
        ($warn -join ';') | Should -Match 'exo-application-access-policies-1\.yml.*not an RBAC4App state file'
    }

    It 'throws when only non-state YAML files are found' {
        $stateFolder = & $script:writeState 'policies-only' @{ 'p.yml' = "Policies:`n  - AppId: `"x`"" }
        { & $script:reportScript -Path $stateFolder -OutputPath (Join-Path $TestDrive 'p.csv') -WarningAction SilentlyContinue } |
            Should -Throw '*No RBAC4App state files*'
    }

    It 'uses the repository module even when an older copy without -Raw is already loaded' {
        $stateFolder = & $script:writeState 'stale' @{ 'app.yaml' = "SchemaVersion: `"4.3`"`nApplication:`n  AppId: `"app-id`"" }
        $stale = New-Module -Name EXORBACforAppManagement -ScriptBlock {
            function ConvertFrom-RBAC4AppYaml { param([string] $Content) }
        } | Import-Module -PassThru -Force
        try {
            $outputPath = Join-Path $TestDrive 'stale.csv'
            $null = & $script:reportScript -Path $stateFolder -OutputPath $outputPath
            @(Import-Csv -LiteralPath $outputPath)[0].'Application.AppId' | Should -Be 'app-id'
        }
        finally {
            Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
            $null = $stale
        }
    }

    It 'throws when the folder has no YAML state files' {
        $empty = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty') -Force
        { & $script:reportScript -Path $empty.FullName -OutputPath (Join-Path $TestDrive 'none.csv') } |
            Should -Throw '*No YAML state files*'
    }
}
