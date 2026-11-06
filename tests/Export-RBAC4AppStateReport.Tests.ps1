#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Export-RBAC4AppStateReport' {
    BeforeAll {
        $script:reportScript = Join-Path $PSScriptRoot '..' 'scripts' 'Export-RBAC4AppStateReport.ps1'
    }

    It 'scans YAML files recursively and includes schema, application, and metadata columns' {
        $stateFolder = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'state') -Force
        $nestedFolder = New-Item -ItemType Directory -Path (Join-Path $stateFolder.FullName 'nested') -Force
        @'
SchemaVersion: "4.2"
GeneratedAt: "2026-11-06T09:00:00Z"
TenantId: "tenant-id"

Application:
  AppId: "app-id"
  SpObjectId: "sp-id"
  DisplayName: "Contoso App"

Metadata:
  OwnerUsername: "owner@contoso.com"
  PCode: "P12345"
  Description: "Mail, calendar"
  NetworkAccessLocation: "Worldwide"
'@ | Set-Content -LiteralPath (Join-Path $stateFolder.FullName 'app.yaml') -Encoding UTF8
        @'
SchemaVersion: "4.1"

Application:
  AppId: "other-app-id"
  DisplayName: "Other App"

Metadata:
  CmdbId: "cmdb-123"
'@ | Set-Content -LiteralPath (Join-Path $nestedFolder.FullName 'other.yml') -Encoding UTF8
        '{"SchemaVersion":"4.2","Application":{"AppId":"ignored"}}' |
            Set-Content -LiteralPath (Join-Path $stateFolder.FullName 'ignored.json') -Encoding UTF8
        $outputPath = Join-Path $TestDrive 'report.csv'

        $result = & $script:reportScript -Path $stateFolder.FullName -OutputPath $outputPath
        $rows = @(Import-Csv -LiteralPath $outputPath)

        $result | Should -Be $outputPath
        $rows.Count | Should -Be 2
        $first = $rows | Where-Object AppId -eq 'app-id'
        $first.SchemaVersion | Should -Be '4.2'
        $first.DisplayName | Should -Be 'Contoso App'
        $first.OwnerUsername | Should -Be 'owner@contoso.com'
        $first.Description | Should -Be 'Mail, calendar'
        $first.NetworkAccessLocation | Should -Be 'Worldwide'
        $second = $rows | Where-Object AppId -eq 'other-app-id'
        $second.SchemaVersion | Should -Be '4.1'
        $second.CmdbId | Should -Be 'cmdb-123'
    }

    It 'does not write the report with -WhatIf' {
        $stateFolder = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'whatif-state') -Force
        @'
SchemaVersion: "4.2"
Application:
  AppId: "app-id"
'@ | Set-Content -LiteralPath (Join-Path $stateFolder.FullName 'app.yaml') -Encoding UTF8
        $outputPath = Join-Path $TestDrive 'whatif.csv'

        & $script:reportScript -Path $stateFolder.FullName -OutputPath $outputPath -WhatIf

        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }
}
